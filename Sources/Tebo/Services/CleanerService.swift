import Foundation

// MARK: - CleanerService
// Does the actual scanning + Trash deletes for Mole-style tabs.
// Small + testable: no SwiftUI here, only FileManager.
// All deletes go: SafetyGate string check at scan time, then
// DeletePipeline (PathValidator + inode recheck + trashItem) at delete time.
// Nothing calls FileManager.trashItem except DeletePipeline.
//
// M2: real recursive sizes (cancellable, symlink-safe, error-tolerant),
// per-app breakdown for Clean, plus purge + installer finders.

/// Handles Clean / Purge / Installer tabs (pure Swift, no Rust needed).
public struct CleanerService: Sendable {

    public init() {}

    // MARK: Clean — per-app breakdown of known-safe locations

    /// List cleanable items inside known-safe folders, biggest first.
    /// Each immediate child gets its own row (e.g. one row per cached app),
    /// so users can review and whitelist precisely — like `mo clean`.
    public func previewSafeLocations(
        whitelist: Set<String>
    ) async -> [ScanResult] {
        var out: [ScanResult] = []
        for loc in MolePaths.safeCleanLocations {
            let abs = MolePaths.absolutePath(homeRelative: loc.relativePath)
            // Skip whitelisted / protected before touching disk (cheap).
            guard SafetyGate.isAllowed(path: abs, whitelist: whitelist) else { continue }
            out += await scanLocation(
                at: abs,
                label: loc.label,
                reason: loc.explanation,
                whitelist: whitelist
            )
            if Task.isCancelled { break }
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes } // Biggest first
    }

    /// One ScanResult per immediate child (recursive sizes for folders,
    /// individual rows for loose files).
    /// Safety rule: no row ever points at the location dir itself — trashing
    /// a "loose files" summary row must not trash the whole folder.
    func scanLocation(
        at path: String,
        label: String,
        reason: String,
        whitelist: Set<String>
    ) async -> [ScanResult] {
        let url = URL(fileURLWithPath: path)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var out: [ScanResult] = []
        for child in children {
            if Task.isCancelled { break }
            let childPath = child.path
            guard SafetyGate.isAllowed(path: childPath, whitelist: whitelist) else { continue }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let size = recursiveSize(at: childPath)
                guard size > 0 else { continue }
                out.append(ScanResult(
                    path: childPath,
                    sizeBytes: size,
                    category: label,
                    reason: reason
                ))
            } else {
                // Loose file: its own row (never a summary row on the parent).
                let size = fileSize(at: child)
                guard size > 0 else { continue }
                out.append(ScanResult(
                    path: childPath,
                    sizeBytes: size,
                    category: label,
                    reason: "\(reason): loose file"
                ))
            }
        }
        return out
    }

    // MARK: Purge — rebuildable project artifact folders

    /// Find e.g. node_modules / target / dist under common project roots.
    /// Skips hidden containers (like Mole) and never descends into a found
    /// artifact (avoids nested double-counting).
    public func findProjectArtifacts(
        whitelist: Set<String>
    ) async -> [ScanResult] {
        var out: [ScanResult] = []
        for root in MolePaths.projectSearchRoots {
            if Task.isCancelled || out.count >= 500 { break }
            guard SafetyGate.isAllowed(path: root, whitelist: whitelist) else { continue }
            out += findArtifacts(under: root, depth: 0, maxDepth: 4, whitelist: whitelist)
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Traversal helper. Internal (not private) so the rules are unit-testable.
    func findArtifacts(
        under path: String,
        depth: Int,
        maxDepth: Int,
        whitelist: Set<String>
    ) -> [ScanResult] {
        var out: [ScanResult] = []
        guard depth <= maxDepth, !Task.isCancelled else { return out }
        let url = URL(fileURLWithPath: path)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return out }

        for child in children {
            if Task.isCancelled || out.count >= 500 { break }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            // Mole skips dot-directory containers by design.
            if child.lastPathComponent.hasPrefix(".") { continue }
            let childPath = child.path
            guard SafetyGate.isAllowed(path: childPath, whitelist: whitelist) else { continue }
            if MolePaths.purgeFolderNames.contains(child.lastPathComponent) {
                // Found an artifact: measure it, don't descend further.
                let size = recursiveSize(at: childPath)
                guard size > 0 else { continue }
                let parent = URL(fileURLWithPath: path).lastPathComponent
                out.append(ScanResult(
                    path: childPath,
                    sizeBytes: size,
                    category: "Purge",
                    reason: "Rebuildable \(child.lastPathComponent) in \(parent)"
                ))
            } else {
                out += findArtifacts(
                    under: childPath, depth: depth + 1,
                    maxDepth: maxDepth, whitelist: whitelist
                )
            }
        }
        return out
    }

    // MARK: Installer — DMG/PKG/ISO/XIP leftovers

    /// Find installer files in Downloads + Desktop (like `mo installer`).
    public func findInstallers(
        whitelist: Set<String>
    ) async -> [ScanResult] {
        var out: [ScanResult] = []
        for dir in MolePaths.installerSearchDirs {
            if Task.isCancelled || out.count >= 1000 { break }
            guard SafetyGate.isAllowed(path: dir, whitelist: whitelist) else { continue }
            let url = URL(fileURLWithPath: dir)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                ],
                options: []
            ) else { continue }
            for child in children {
                if Task.isCancelled || out.count >= 1000 { break }
                let values = try? child.resourceValues(
                    forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                    ]
                )
                // Files only — never follow symlinks, never descend.
                guard values?.isDirectory != true, values?.isSymbolicLink != true else { continue }
                let ext = child.pathExtension.lowercased()
                guard MolePaths.installerExtensions.contains(ext) else { continue }
                let childPath = child.path
                guard SafetyGate.isAllowed(path: childPath, whitelist: whitelist) else { continue }
                let size = Int64(values?.fileSize ?? 0)
                guard size > 0 else { continue }
                // A month-old installer has almost certainly served its purpose; a fresh download
                // may still be about to be used, so it is listed but never ticked by default.
                let ageInDays = values?.contentModificationDate
                    .map { Date.now.timeIntervalSince($0) / 86_400 } ?? 0
                out.append(ScanResult(
                    path: childPath,
                    sizeBytes: size,
                    category: "Installer",
                    reason: "Installer file in \\(URL(fileURLWithPath: dir).lastPathComponent)",
                    recommendedForSelection: ageInDays >= 30
                ))
            }
        }
        return out.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: Move to Trash (reversible, like Mole's mole_delete)

    /// Move approved paths to Trash through DeletePipeline, the app's only
    /// path to FileManager.trashItem. Returns freed bytes; per-path outcomes
    /// are in the pipeline's DeleteReport (and the OperationLog).
    /// Never uses rm -rf. Fails closed on any error.
    @discardableResult
    public func moveToTrash(paths: [String], whitelist: Set<String>) async -> Int64 {
        let report = await DeletePipeline().trash(paths: paths, whitelist: whitelist)
        return report.freedBytes
    }

    // MARK: Sizing helpers

    /// Recursive folder/file size. Symlink-safe (never follows links),
    /// error-tolerant (unreadable subtrees are skipped, not fatal),
    /// cancellation-aware (checks every 256 files).
    func recursiveSize(at path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        // Single file? Just return its size.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return fileSize(at: url)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true } // Keep going past permission errors
        ) else { return 0 }

        var total: Int64 = 0
        var seen = 0
        for case let file as URL in enumerator {
            seen += 1
            // Cheap periodic cancellation check (not per file).
            if seen % 256 == 0, Task.isCancelled { break }
            // Each resourceValues lookup returns autoreleased objects. A scan can walk hundreds of
            // thousands of files on a concurrency thread that has no run loop to drain them, so the
            // pool is drained per file: peak memory stays flat regardless of tree size.
            total += autoreleasepool {
                guard let values = try? file.resourceValues(
                    forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
                ) else { return 0 }
                // Never descend into symlinked dirs (loop protection).
                if values.isSymbolicLink == true, values.isDirectory == true {
                    enumerator.skipDescendants()
                    return 0
                }
                // Count files only — directory metadata would double-count.
                return values.isDirectory == true ? 0 : Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Single-file size, 0 when unreadable.
    private func fileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

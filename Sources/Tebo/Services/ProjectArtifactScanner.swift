import Darwin
import Foundation

struct ProjectArtifactReport: Sendable {
    let rows: [ScanResult]
    let kept: [AdvisoryRow]
    let partial: Bool
}

struct ProjectArtifactScanner: Sendable {
    let roots: [String]
    let maxDepth: Int
    private let isCloudPlaceholder: @Sendable (URL) -> Bool

    init(roots: [String] = MolePaths.projectSearchRoots, maxDepth: Int = 6,
         isCloudPlaceholder: @escaping @Sendable (URL) -> Bool = ProjectArtifactScanner.hasCloudPlaceholderMetadata) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.isCloudPlaceholder = isCloudPlaceholder
    }

    func scan(whitelist: Set<String>, timeout: TimeInterval = 60) async -> ProjectArtifactReport {
        let worker = Task.detached(priority: .utility) { await scanOffMain(whitelist: whitelist, timeout: timeout) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private func scanOffMain(whitelist: Set<String>, timeout: TimeInterval) async -> ProjectArtifactReport {
        let deadline = Date.now.addingTimeInterval(timeout)
        var pending = roots.map { (URL(fileURLWithPath: $0).standardizedFileURL, 0) }
        var kept: [AdvisoryRow] = []
        var visited: Set<String> = []
        var partial = false
        var walked = 0

        func keep(_ url: URL, _ reason: String) {
            kept.append(.init(id: url.path, title: url.lastPathComponent, detail: reason, source: url.path))
        }

        while let (directory, depth) = pending.popLast() {
            if Task.isCancelled || Date.now >= deadline || walked > 20_000 || kept.count >= 500 {
                partial = true
                break
            }
            guard visited.insert(directory.path).inserted else { continue }
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                partial = true
                keep(directory, "Directory could not be verified; contents retained read-only")
                continue
            }
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                partial = true
                keep(directory, "Search root is not a readable physical directory; contents retained")
                continue
            }
            if isCloudPlaceholder(directory) {
                keep(directory, "Cloud-managed placeholder; contents were not traversed")
                continue
            }
            guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey]) else {
                partial = true
                keep(directory, "Directory could not be read; contents retained read-only")
                continue
            }

            for child in children {
                walked += 1
                if Task.isCancelled || Date.now >= deadline || walked > 20_000 || kept.count >= 500 {
                    partial = true
                    break
                }
                let name = child.lastPathComponent
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                    partial = true
                    keep(child, "Entry could not be verified; contents retained read-only")
                    continue
                }
                if [".git", ".hg", ".svn"].contains(name) { continue }
                if isCloudPlaceholder(child) {
                    keep(child, "Cloud-managed placeholder; contents were not traversed")
                    continue
                }
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    if values.isSymbolicLink == true,
                       MolePaths.purgeFolderNames.contains(name) || name == ".worktrees" {
                        keep(child, name == ".worktrees"
                            ? "Git worktree link is not inspected or selected"
                            : "Symbolic-link artifact is not inspected or selected")
                    }
                    continue
                }
                if name == ".worktrees" {
                    keep(child, "Git worktree data is retained read-only")
                    continue
                }
                if MolePaths.purgeFolderNames.contains(name) {
                    keep(child, readOnlyReason(for: child, whitelist: whitelist))
                    continue
                }
                if depth < maxDepth && (!name.hasPrefix(".") || name == ".codex") {
                    pending.append((child, depth + 1))
                }
            }
        }
        return ProjectArtifactReport(rows: [], kept: kept, partial: partial)
    }

    private func readOnlyReason(for url: URL, whitelist: Set<String>) -> String {
        if let reason = PathValidator.validate(path: url.path, whitelist: whitelist) {
            return "\(reason.rawValue); artifact kept read-only"
        }
        if url.lastPathComponent == "vendor" { return "Vendored source is kept read-only" }
        if hasRepositoryAncestor(for: url) { return "Project repository contents are kept read-only" }
        return "No reviewed tool-specific rebuildability proof; retained for manual review"
    }

    // Called by the owning view through DeletePipeline's final additional validator.
    // Project artifacts currently have no supported deletion policy, so every path is
    // refused. The live bounded walk still distinguishes newly active and unknown data.
    func protectionReason(for url: URL, whitelist: Set<String>) async -> String? {
        if let reason = PathValidator.validate(path: url.path, whitelist: whitelist) { return reason.rawValue }
        guard MolePaths.purgeFolderNames.contains(url.lastPathComponent) else { return "Not a reviewed project artifact folder" }
        guard isWithinConfiguredRoot(url) else { return "Artifact is outside the reviewed project roots" }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else {
            return "Artifact identity could not be verified; contents retained"
        }
        if isCloudPlaceholder(url) { return "Cloud-managed placeholder; contents retained" }
        if url.lastPathComponent == "vendor" { return "Vendored source is retained" }
        if hasRepositoryAncestor(for: url) { return "Repository or worktree contents are retained" }

        let measured = FileTreeMeasurement.read(url, timeout: 4, stopAtSafetyEvidence: true, whitelist: whitelist)
        if measured.containsRepository { return "Contains a nested Git, Hg, or SVN repository" }
        if measured.containsCredentials { return "Contains credentials or deployment keys" }
        guard measured.status == .complete, let newest = measured.newestModification else {
            return "Project content or activity scan incomplete; contents retained"
        }
        if newest >= Date.now.addingTimeInterval(-7 * 86_400) {
            return "Recent project activity; contents retained"
        }
        return "No reviewed tool-specific rebuildability policy; project artifact retained read-only"
    }

    private func isWithinConfiguredRoot(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    private func isAtOrWithinConfiguredRoot(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    private func hasRepositoryAncestor(for url: URL) -> Bool {
        var ancestor = url.resolvingSymlinksInPath().deletingLastPathComponent()
        while isAtOrWithinConfiguredRoot(ancestor) {
            for marker in [".git", ".hg", ".svn"] where
                FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(marker).path) {
                return true
            }
            if ancestor.lastPathComponent == ".worktrees" { return true }
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }
        return false
    }

    private static func hasCloudPlaceholderMetadata(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, !FileTreeMeasurement.isDataless(flags: info.st_flags),
              let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey]),
              values.volumeIsLocal == true else { return true }
        return values.isUbiquitousItem == true
    }
}

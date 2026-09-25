import AppKit
import Darwin
import Foundation

// MARK: - TargetScanner
// Turns the ported Mole tables (Services/MoleTables/) into real rows on this Mac.
//
// Division of responsibility, so nothing here can ever delete something it should not:
//   * This scanner only READS. It measures sizes and reports.
//   * Rows the app must not remove itself (report-only targets, targets needing root, targets whose
//     owning app is running) are returned as advisories, never as deletion candidates. Mole does the
//     same with its deferred-skip list; deleting a cache under a live app is how you corrupt it.
//   * Deletion happens only through DeletePipeline after the user picks rows.

/// A row shown for information, with no checkbox and no delete path.
public struct AdvisoryRow: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let detail: String
    /// Upstream citation, so the claim can be checked against Mole's source.
    public let source: String
    /// Heading this entry belongs under in the review panel. The producer sets it when it knows
    /// why the entry was kept; empty means the panel derives one from `detail`.
    public let group: String

    public init(id: String, title: String, detail: String, source: String, group: String = "") {
        self.id = id
        self.title = title
        self.detail = detail
        self.source = source
        self.group = group
    }

    /// The explanation half of the row, used for grouping in the review panel.
    public var reasonPhrase: String { detail }

    /// The filesystem path this row points at, when it has one. Kept rows carry it after
    /// "kept: " in `source`; table rows carry an upstream citation instead, so they have none.
    public var pathForThumb: String {
        if let range = source.range(of: "kept: ") { return String(source[range.upperBound...]) }
        return source.hasPrefix("/") ? source : ""
    }
}

/// Result of one Mole-table sweep.
public struct MoleScanOutcome: Sendable {
    /// Rows the user may select and move to Trash.
    public let deletable: [ScanResult]
    /// Rows reported but never deletable by this app.
    public let advisories: [AdvisoryRow]
    /// How many table rows point at something this Mac does not have.
    public let absentLocationCount: Int
    /// True when the scan stopped early (user cancelled, or the row cap was hit).
    public let truncated: Bool

    public init(
        deletable: [ScanResult] = [],
        advisories: [AdvisoryRow] = [],
        absentLocationCount: Int = 0,
        truncated: Bool = false
    ) {
        self.deletable = deletable
        self.advisories = advisories
        self.absentLocationCount = absentLocationCount
        self.truncated = truncated
    }
}

public struct TargetScanner: Sendable {

    /// Hard ceiling so a pathological table cannot pin the CPU or flood the UI.
    private static let rowCap = 800
    /// Per-target ceiling for directory sweeps ("$dir"/* rows).
    private static let sweepCap = 200

    private let home: String
    /// Names of running apps/processes, used for Mole's "close the app first" guards.
    /// Required rather than defaulted on purpose: a forgotten default would silently skip the
    /// guard and let a cache be cleaned under a live app, so the caller must supply it.
    private let runningProcessNames: Set<String>

    public init(home: String = NSHomeDirectory(), runningProcessNames: Set<String>) {
        self.home = home
        self.runningProcessNames = runningProcessNames
    }

    /// Native replacement for Mole's pgrep probes: NSWorkspace already knows what is running, so we
    /// never fork a process to find out. MainActor because NSWorkspace is.
    @MainActor
    public static func liveRunningProcessNames() -> Set<String> {
        var names: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier { names.insert(bundleID.lowercased()) }
            if let name = app.localizedName { names.insert(name.lowercased()) }
            if let executable = app.executableURL?.lastPathComponent { names.insert(executable.lowercased()) }
        }
        return names
    }

    // MARK: - Entry point

    public func scan(
        targets: [CleanTarget] = MoleTables.allTargets,
        whitelist: Set<String>
    ) async -> MoleScanOutcome {
        var deletable: [ScanResult] = []
        var advisories: [AdvisoryRow] = []
        var absent = 0
        var truncated = false

        for target in targets {
            if Task.isCancelled { return MoleScanOutcome(deletable: deletable, advisories: advisories, absentLocationCount: absent, truncated: true) }
            if deletable.count >= Self.rowCap { truncated = true; break }

            let resolved = MolePathResolver.resolve(target.path, home: home)
            // A wildcard row's table path is a pattern, so it does not exist as a literal: the
            // existence question only makes sense after expansion, handled below.
            let exists = FileManager.default.fileExists(atPath: resolved)

            if target.needsAdmin {
                // Mole runs these through sudo; Tebo deliberately does not ask for root in 1.0.
                advisories.append(AdvisoryRow(
                    id: "admin:\(target.label)",
                    title: target.label,
                    detail: "Needs an administrator password, which Tebo never asks for. Not touched.",
                    source: target.source,
                    group: "Needs administrator rights"
                ))
                continue
            }
            if target.reportOnly {
                // Sizing is best-effort here and deliberately skipped for whole-volume paths: walking
                // "/" or "/Volumes" for a row we will not delete proves nothing and can take minutes.
                let size = exists && Self.isMeasurable(resolved)
                    ? CleanerService().recursiveSize(at: resolved)
                    : 0
                let sizeText = size > 0 ? " (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))" : ""
                let whereText = exists && !resolved.contains("*") ? " Location: \(resolved)." : ""
                advisories.append(AdvisoryRow(
                    id: "report:\(target.label)",
                    title: target.label,
                    detail: "\(target.explanation)\(sizeText)\(whereText) Not removable from here.",
                    source: target.source,
                    group: "Reported only, nothing to delete"
                ))
                continue
            }
            if target.kind.requiresExistingLiteralPath && !exists {
                absent += 1
                continue
            }
            if let guardBlock = blockedByRunningProcess(target) {
                advisories.append(AdvisoryRow(
                    id: "running:\(target.label)",
                    title: target.label,
                    detail: "\(guardBlock) is running. Close it and rescan.",
                    source: target.source,
                    group: "In use right now"
                ))
                continue
            }

            let paths = expand(target, resolved: resolved)
            if paths.isEmpty { absent += 1; continue }

            var rows: [ScanResult] = []
            for path in paths {
                if Task.isCancelled { break }
                guard SafetyGate.isAllowed(path: path, whitelist: whitelist) else { continue }
                // Pool per candidate: measuring a big cache walks thousands of files, and each one
                // autoreleases. Without this the footprint grows for the whole scan.
                let row = autoreleasepool { () -> ScanResult? in
                    let size = CleanerService().recursiveSize(at: path)
                    guard size > 0 else { return nil }
                    return ScanResult(
                        path: path,
                        sizeBytes: size,
                        category: target.group.rawValue,
                        reason: reasonText(target),
                        // Mole's own tier decides this, not the UI: only rebuildable caches and
                        // logs it marks "safe", never something needing admin or reported only.
                        recommendedForSelection: target.risk == .safe
                            && !target.needsAdmin
                            && !target.reportOnly
                    )
                }
                if let row { rows.append(row) }
            }

            if target.kind.sweepsChildren && rows.count > Self.sweepCap {
                // Report the biggest slice and say so instead of silently dropping rows.
                rows.sort { $0.sizeBytes > $1.sizeBytes }
                let hidden = rows.count - Self.sweepCap
                truncated = true
                advisories.append(AdvisoryRow(
                    id: "cap:\(target.label)",
                    title: target.label,
                    detail: "\(hidden) more \(hidden == 1 ? "entry" : "entries") in this folder were not listed.",
                    source: target.source,
                    group: "Listed partially (safety cap)"
                ))
                rows = Array(rows.prefix(Self.sweepCap))
            }
            deletable += rows
        }

        return MoleScanOutcome(
            deletable: deletable.sorted { $0.sizeBytes > $1.sizeBytes },
            advisories: advisories,
            absentLocationCount: absent,
            truncated: truncated
        )
    }

    // MARK: - Path expansion

    /// Concrete paths a target covers. Never returns the table path if the row is a wildcard.
    private func expand(_ target: CleanTarget, resolved: String) -> [String] {
        switch target.kind {
        case .directorySweep:
            return children(of: resolved)

        case .directory, .file:
            return [resolved]

        case .glob:
            let parent = (resolved as NSString).deletingLastPathComponent
            let pattern = (resolved as NSString).lastPathComponent
            return children(of: parent).filter { name in
                fnmatch(pattern, (name as NSString).lastPathComponent, FNM_PERIOD) == 0
            }

        case .frameworkVersions(let framework):
            return frameworkVersions(inApp: resolved, framework: framework, pruneRule: target.pruneRule)

        case .findRule(let maxDepth, let minAgeMinutes, let filesOnly):
            return byAge(
                under: resolved, maxDepth: maxDepth ?? 6,
                minAgeMinutes: minAgeMinutes, filesOnly: filesOnly
            )
        }
    }

    private func children(of directory: String) -> [String] {
        let url = URL(fileURLWithPath: directory)
        // Pool per directory: contentsOfDirectory autoreleases a URL for every entry.
        return autoreleasepool {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
            ) else { return [] }
            return entries.map(\.path)
        }
    }

    /// Chromium-style framework pruning: keep the version the `Current` symlink points at.
    private func frameworkVersions(
        inApp app: String, framework: String, pruneRule: MolePruneRule?
    ) -> [String] {
        let versionsDir = "\(app)/Contents/Frameworks/\(framework)/Versions"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else { return [] }
        var keep: Set<String> = ["Current"]
        if case .keepCurrentSymlinkTarget = pruneRule ?? .keepCurrentSymlinkTarget {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(versionsDir)/Current") {
                keep.insert((target as NSString).lastPathComponent)
            }
        }
        return entries.filter { !keep.contains($0) }.map { "\(versionsDir)/\($0)" }
    }

    /// Depth- and age-limited walk (Mole's `find -maxdepth N -mmin +M`).
    private func byAge(
        under root: String, maxDepth: Int, minAgeMinutes: Int, filesOnly: Bool
    ) -> [String] {
        let cutoff = Date().addingTimeInterval(-Double(minAgeMinutes) * 60)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var out: [String] = []
        for case let url as URL in enumerator {
            if Task.isCancelled || out.count >= Self.rowCap { break }
            let depth = url.pathComponents.count - URL(fileURLWithPath: root).pathComponents.count
            if depth > maxDepth { enumerator.skipDescendants(); continue }
            // Pool per entry: resourceValues autoreleases, and this walk can be long.
            let hit = autoreleasepool { () -> Bool in
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { enumerator.skipDescendants(); return false }
                if filesOnly, values?.isDirectory == true { return false }
                guard let modified = values?.contentModificationDate, modified < cutoff else { return false }
                return true
            }
            if hit { out.append(url.path) }
        }
        return out
    }

    // MARK: - Process guard

    /// Why this target must wait, or nil when it is clear to clean.
    private func blockedByRunningProcess(_ target: CleanTarget) -> String? {
        guard let guardSpec = target.processGuard else { return nil }
        for name in guardSpec.exactProcessNames where runningProcessNames.contains(name.lowercased()) {
            return guardSpec.family
        }
        return nil
    }

    // MARK: - Text

    /// True when walking this path just to report a size is reasonable. A single-component path is
    /// a volume or system root; those belong in an advisory without a size.
    private static func isMeasurable(_ path: String) -> Bool {
        let normalized = SafetyGate.normalized(path)
        guard normalized != "/" else { return false }
        return normalized.split(separator: "/").count > 1
    }

    private func reasonText(_ target: CleanTarget) -> String {
        var text = target.explanation
        if target.risk == .review {
            text = "Review first — \(text)"
        }
        if let prune = target.pruneRule, case .keepCurrentSymlinkTarget = prune {
            text += " Keeps the version the app currently uses."
        }
        return text
    }
}

private extension MoleTargetKind {
    /// True for rows that turn one table entry into many files.
    var sweepsChildren: Bool {
        switch self {
        case .directorySweep, .glob, .findRule: return true
        case .directory, .file, .frameworkVersions: return false
        }
    }

    /// False only for wildcard rows, whose table path is a pattern rather than a real location.
    var requiresExistingLiteralPath: Bool {
        if case .glob = self { return false }
        return true
    }
}

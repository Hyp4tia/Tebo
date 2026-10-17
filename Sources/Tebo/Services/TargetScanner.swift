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

/// Snapshot of native process information. Either field may be nil when that part
/// of the inventory could not be read; nil is unknown, never an empty process list.
public struct MoleProcessInventory: Sendable, Equatable {
    public let names: Set<String>?
    public let executablePaths: Set<String>?

    public init(names: Set<String>?, executablePaths: Set<String>?) {
        self.names = names.map { Set($0.map { $0.lowercased() }) }
        self.executablePaths = executablePaths.map { Set($0.map { $0.lowercased() }) }
    }
}

public struct TargetScanner: Sendable {

    /// Hard ceiling so a pathological table cannot pin the CPU or flood the UI.
    private static let rowCap = 800
    /// Per-target ceiling for directory sweeps ("$dir"/* rows).
    private static let sweepCap = 200

    private enum ProcessGuardBlock {
        case active(String)
        case unknown(String)

        var family: String {
            switch self {
            case .active(let family), .unknown(let family): return family
            }
        }

        var isUnknown: Bool {
            if case .unknown = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .active(let family): return "\(family) is running. Close it and rescan."
            case .unknown(let family): return "\(family) process state is unknown; keep it and rescan."
            }
        }
    }

    private struct GuardedScope {
        let pattern: String
        let block: ProcessGuardBlock
    }

    private let home: String
    /// Process names and executable paths are independent inventories. A missing
    /// field means unknown; guarded targets fail closed on the field they use.
    private let runningProcessNames: Set<String>?
    private let runningProcessPaths: Set<String>?
    /// Scanner-level work-ceiling overrides. nil resolves the target's own tier;
    /// tests set them to force partial walks regardless of the rule.
    private let measurementEntryLimit: Int?
    private let measurementTimeout: TimeInterval?
    private let directoryListing: (@Sendable (String) -> [String])?
    private let simulatorActivityProbe: SimulatorActivityProbe.Probe
    /// Fresh process inventory for the removal boundary's booted-simulator
    /// bracket, whose probe can take seconds. nil skips the re-check.
    private let inventoryRefresh: (@Sendable () async -> MoleProcessInventory?)?
    /// Open-handle probe seam for tests; nil runs the live lsof.
    private let activityProbe: CleanupActivityGuard.Probe?

    public init(home: String = NSHomeDirectory(), runningProcessNames: Set<String>?,
                runningProcessPaths: Set<String>? = nil,
                measurementEntryLimit: Int? = nil, measurementTimeout: TimeInterval? = nil,
                directoryListing: (@Sendable (String) -> [String])? = nil,
                simulatorActivityProbe: SimulatorActivityProbe.Probe? = nil,
                inventoryRefresh: (@Sendable () async -> MoleProcessInventory?)? = nil,
                activityProbe: CleanupActivityGuard.Probe? = nil) {
        self.home = home
        self.runningProcessNames = runningProcessNames.map { Set($0.map { $0.lowercased() }) }
        self.runningProcessPaths = runningProcessPaths.map { Set($0.map { $0.lowercased() }) }
        self.measurementEntryLimit = measurementEntryLimit
        self.measurementTimeout = measurementTimeout
        self.directoryListing = directoryListing
        self.simulatorActivityProbe = simulatorActivityProbe ?? SimulatorActivityProbe.live
        self.inventoryRefresh = inventoryRefresh
        self.activityProbe = activityProbe
    }

    public init(home: String = NSHomeDirectory(), processInventory: MoleProcessInventory?,
                measurementEntryLimit: Int? = nil, measurementTimeout: TimeInterval? = nil,
                directoryListing: (@Sendable (String) -> [String])? = nil,
                simulatorActivityProbe: SimulatorActivityProbe.Probe? = nil,
                inventoryRefresh: (@Sendable () async -> MoleProcessInventory?)? = nil,
                activityProbe: CleanupActivityGuard.Probe? = nil) {
        self.init(home: home, runningProcessNames: processInventory?.names,
                  runningProcessPaths: processInventory?.executablePaths,
                  measurementEntryLimit: measurementEntryLimit, measurementTimeout: measurementTimeout,
                  directoryListing: directoryListing, simulatorActivityProbe: simulatorActivityProbe,
                  inventoryRefresh: inventoryRefresh, activityProbe: activityProbe)
    }

    /// One process's readable identity facts. The kernel name is denied for
    /// other users' processes (proc_name returns EPERM for roughly a quarter of
    /// the table here); the executable path stays readable and names the
    /// process the same way Mole's pgrep does.
    struct ProcessFacts: Sendable, Equatable {
        let name: String?
        let executablePath: String?
    }

    /// Merges process facts into an inventory. A pid is only unaccounted for
    /// when neither its name nor its executable path could be read; either one
    /// identifies the process.
    static func inventory(from facts: [ProcessFacts]) -> MoleProcessInventory {
        var names: Set<String> = []
        var executablePaths: Set<String> = []
        var namesComplete = true
        var pathsComplete = true
        for fact in facts {
            if let path = fact.executablePath {
                let lower = path.lowercased()
                executablePaths.insert(lower)
                names.insert(URL(fileURLWithPath: lower).lastPathComponent)
            } else {
                pathsComplete = false
            }
            if let name = fact.name {
                names.insert(name.lowercased())
            } else if fact.executablePath == nil {
                namesComplete = false
            }
        }
        return MoleProcessInventory(names: namesComplete ? names : nil,
                                    executablePaths: pathsComplete ? executablePaths : nil)
    }

    /// Native PID/executable inventory, enriched with NSWorkspace bundle IDs and names.
    /// No shell and no blocking wait; failure to enumerate a field is represented as nil.
    @MainActor
    public static func liveProcessInventory() -> MoleProcessInventory? {
        let initialCount = proc_listallpids(nil, 0)
        guard initialCount > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(initialCount) + 32)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0, Int(count) < pids.count else { return nil }

        var facts: [ProcessFacts] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameSize = nameBuffer.withUnsafeMutableBufferPointer {
                proc_name(pid, $0.baseAddress, UInt32($0.count))
            }
            var name: String?
            if nameSize > 0, let terminator = nameBuffer.firstIndex(of: 0) {
                name = String(decoding: nameBuffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }

            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let pathSize = pathBuffer.withUnsafeMutableBufferPointer {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            var path: String?
            if pathSize > 0, let terminator = pathBuffer.firstIndex(of: 0) {
                path = String(decoding: pathBuffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            facts.append(ProcessFacts(name: name, executablePath: path))
        }

        let merged = inventory(from: facts)
        var names = merged.names ?? []
        var executablePaths = merged.executablePaths ?? []
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier { names.insert(bundleID.lowercased()) }
            if let name = app.localizedName { names.insert(name.lowercased()) }
            if let executableURL = app.executableURL {
                names.insert(executableURL.lastPathComponent.lowercased())
                executablePaths.insert(executableURL.path.lowercased())
            }
        }
        return MoleProcessInventory(
            names: merged.names == nil ? nil : names,
            executablePaths: merged.executablePaths == nil ? nil : executablePaths
        )
    }

    /// Compatibility view for callers that need only exact process-name checks.
    @MainActor
    public static func liveRunningProcessNames() -> Set<String>? {
        liveProcessInventory()?.names
    }

    // MARK: - Rule contracts

    /// Effective work ceiling: a scanner-level override (tests) replaces the tier
    /// field it sets; everything else comes from the target's own contract.
    private func budget(for target: CleanTarget) -> MoleScanBudget {
        MoleScanBudget(
            entryLimit: measurementEntryLimit ?? target.scanBudget.entryLimit,
            measurementTimeout: measurementTimeout ?? target.scanBudget.measurementTimeout,
            activityProbeTimeout: target.scanBudget.activityProbeTimeout
        )
    }

    private func contract(for target: CleanTarget) -> MoleRuleContract {
        MoleRuleContract(budget: budget(for: target), evidencePolicy: target.evidencePolicy,
                         containmentRoot: CleanTarget.containmentRoot(for: target.path, home: home))
    }

    /// Open-handle check with the rule's own probe ceiling and the test seam.
    private func activityReason(for path: String, timeout: TimeInterval) async -> String? {
        await CleanupActivityGuard.reason(for: path, timeout: timeout, probe: activityProbe)
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
        // The booted-device probe can take seconds; one answer per scan serves
        // every simulator-owned target (Mole probes per guard evaluation).
        var simulatorActivityState: SimulatorActivityProbe.State?
        let activeScopes = guardedScopes(in: targets)

        for target in targets {
            if Task.isCancelled { return MoleScanOutcome(deletable: deletable, advisories: advisories, absentLocationCount: absent, truncated: true) }
            if deletable.count >= Self.rowCap { truncated = true; break }

            let resolved = MolePathResolver.resolve(target.path, home: home)
            // A wildcard row's table path is a pattern, so it does not exist as a literal: the
            // existence question only makes sense after expansion, handled below.
            let exists = FileManager.default.fileExists(atPath: resolved)
            let ruleContract = contract(for: target)

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
                let measured = exists && Self.isMeasurable(resolved)
                    ? FileTreeMeasurement.read(URL(fileURLWithPath: resolved), entryLimit: ruleContract.budget.entryLimit,
                                               timeout: ruleContract.budget.measurementTimeout, stopAtSafetyEvidence: true,
                                               whitelist: whitelist, policy: ruleContract.evidencePolicy,
                                               containmentRoot: ruleContract.containmentRoot) : nil
                let size = measured?.protectedPath == nil ? (measured?.bytes ?? 0) : 0
                let sizeText = size > 0 ? " (\(measured?.status == .complete ? "" : "≥ ")\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))" : ""
                let whereText = exists && !resolved.contains("*") ? " Location: \(resolved)." : ""
                let protectedText = measured?.protectedPath.map { " Protected content at \($0) was retained." } ?? ""
                advisories.append(AdvisoryRow(
                    id: "report:\(target.label)",
                    title: target.label,
                    detail: "\(target.explanation)\(protectedText)\(sizeText)\(whereText) Not removable from here.",
                    source: target.source,
                    group: "Reported only, nothing to delete"
                ))
                continue
            }
            if target.eligibility == .unsupported {
                advisories.append(AdvisoryRow(
                    id: "unsupported:\(target.ruleID)",
                    title: target.label,
                    detail: "This cleanup rule has no supported removal policy in Tebo; the location is read-only.",
                    source: target.source,
                    group: "Unsupported cleanup rule"
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
                    detail: guardBlock.message,
                    source: target.source,
                    group: guardBlock.isUnknown ? "Process state unknown" : "In use right now"
                ))
                continue
            }

            let paths: [String]
            if case .glob = target.kind {
                let expanded = expandGlobTarget(
                    resolved, pruneRule: target.pruneRule,
                    whitelist: whitelist, activeScopes: activeScopes
                )
                paths = expanded.paths
                if expanded.truncated {
                    truncated = true
                    advisories.append(AdvisoryRow(id: "glob-cap:\(target.label)", title: target.label,
                        detail: "Some matching locations were not checked because the scan limit was reached.",
                        source: target.source, group: "Listed partially (safety cap)"))
                }
            } else {
                paths = expand(target, resolved: resolved, whitelist: whitelist, activeScopes: activeScopes)
            }
            if paths.isEmpty { absent += 1; continue }

            // Mole brackets simulator-owned cleanup around a booted-device probe;
            // a booted device or an unverifiable state defers the whole target.
            if target.processGuard?.probesBootedSimulator == true {
                let state: SimulatorActivityProbe.State
                if let cached = simulatorActivityState {
                    state = cached
                } else {
                    state = await simulatorActivityProbe()
                    simulatorActivityState = state
                }
                if state != .idle {
                    advisories.append(AdvisoryRow(
                        id: "simulator:\(target.label)",
                        title: target.label,
                        detail: state == .active
                            ? "A simulator is booted. Shut it down and rescan."
                            : "Simulator activity could not be verified; keep it and rescan.",
                        source: target.source,
                        group: state == .active ? "In use right now" : "Process state unknown"
                    ))
                    continue
                }
            }

            var rows: [ScanResult] = []
            for path in paths {
                if Task.isCancelled { break }
                guard SafetyGate.isAllowed(path: path, whitelist: whitelist) else { continue }
                if let guardBlock = protectedFamily(for: path, scopes: activeScopes) {
                    advisories.append(AdvisoryRow(id: "running-path:\(target.label):\(path)", title: target.label,
                        detail: guardBlock.message, source: path,
                        group: guardBlock.isUnknown ? "Process state unknown" : "In use right now"))
                    continue
                }
                if let reason = await activityReason(for: path, timeout: ruleContract.budget.activityProbeTimeout) {
                    advisories.append(AdvisoryRow(id: "activity:\(target.label):\(path)", title: target.label,
                        detail: reason, source: path, group: "In use or activity unverified"))
                    continue
                }
                // Pool per candidate: measuring a big cache walks thousands of files, and each one
                // autoreleases. Without this the footprint grows for the whole scan.
                let measured = autoreleasepool {
                    FileTreeMeasurement.read(URL(fileURLWithPath: path), entryLimit: ruleContract.budget.entryLimit,
                                             timeout: ruleContract.budget.measurementTimeout, stopAtSafetyEvidence: true,
                                             whitelist: whitelist, policy: ruleContract.evidencePolicy,
                                             containmentRoot: ruleContract.containmentRoot)
                }
                if let protectedPath = measured.protectedPath {
                    advisories.append(AdvisoryRow(id: "protected-content:\(target.label):\(path)",
                        title: target.label,
                        detail: "Contains protected data at \(protectedPath); the parent item was kept.",
                        source: path, group: "Protected data retained"))
                    continue
                }
                if measured.containsSymbolicLinks {
                    advisories.append(AdvisoryRow(id: "protected-content:\(target.label):\(path)",
                        title: target.label, detail: "Contains a symbolic link; the item was kept.",
                        source: path, group: "Protected data retained"))
                    continue
                }
                if measured.containsCloudPlaceholders {
                    advisories.append(AdvisoryRow(id: "protected-content:\(target.label):\(path)",
                        title: target.label, detail: "Contains an offline/cloud placeholder; the item was kept.",
                        source: path, group: "Protected data retained"))
                    continue
                }
                if measured.containsRepository || measured.containsCredentials {
                    advisories.append(AdvisoryRow(id: "protected-content:\(target.label):\(path)", title: target.label,
                        detail: measured.containsRepository
                            ? "Contains repository metadata; the item was kept."
                            : "Contains credential material; the item was kept.",
                        source: path, group: "Protected data retained"))
                    continue
                }
                if measured.status != .complete {
                    advisories.append(AdvisoryRow(id: "size:\(target.label):\(path)", title: target.label,
                        detail: measured.status == .unavailable ? "Could not measure this item; kept."
                            : "The safety walk is incomplete; this item remains read-only.",
                        source: path, group: "Incomplete measurements"))
                    continue
                }
                guard measured.bytes > 0, measured.status != .unavailable else { continue }
                let row = ScanResult(
                        path: path,
                        sizeBytes: measured.bytes,
                        category: target.group.rawValue,
                        reason: reasonText(target),
                        // Descriptive risk metadata cannot upgrade a manual or unsupported policy.
                        recommendedForSelection: target.eligibility == .rebuildableCache && target.risk == .safe
                            && !target.needsAdmin
                            && !target.reportOnly
                            && measured.status == .complete,
                        isSizeComplete: measured.status == .complete,
                        cleanupSource: .moleRule(target.ruleID)
                    )
                rows.append(row)
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
    private func expand(_ target: CleanTarget, resolved: String, whitelist: Set<String>,
                        activeScopes: [GuardedScope]) -> [String] {
        switch target.kind {
        case .directorySweep:
            return applyPruneRule(children(of: resolved), rule: target.pruneRule)

        case .directory, .file:
            return target.pruneRule == nil ? [resolved] : []

        case .glob:
            return expandGlobTarget(resolved, pruneRule: target.pruneRule,
                                    whitelist: whitelist, activeScopes: activeScopes).paths

        case .groupContainerLeaves:
            guard target.pruneRule == nil else { return [] }
            return groupContainerLeaves(under: resolved, whitelist: whitelist, activeScopes: activeScopes)

        case .frameworkVersions(let framework):
            return frameworkVersions(inApp: resolved, framework: framework,
                                    pruneRule: target.pruneRule, whitelist: whitelist)

        case .findRule(let maxDepth, let minAgeMinutes, let filesOnly):
            let candidates = byAge(
                under: resolved, maxDepth: maxDepth ?? 6,
                minAgeMinutes: minAgeMinutes, filesOnly: filesOnly
            )
            return applyPruneRule(candidates, rule: target.pruneRule)
        }
    }

    private func expandGlobTarget(
        _ pattern: String, pruneRule: MolePruneRule?, whitelist: Set<String>, activeScopes: [GuardedScope]
    ) -> (paths: [String], truncated: Bool) {
        let expanded = expandGlob(pattern, whitelist: whitelist, activeScopes: activeScopes)
        guard let pruneRule else { return expanded }
        // An incomplete sibling inventory cannot establish which versions must be retained.
        guard !expanded.truncated else { return ([], true) }
        let siblings = Dictionary(grouping: expanded.paths) { ($0 as NSString).deletingLastPathComponent }
        let paths = siblings.sorted { $0.key < $1.key }.flatMap { applyPruneRule($0.value, rule: pruneRule) }
        return (paths, false)
    }

    /// Expand Group Containers only through allowed roots and return direct regular-file
    /// leaves from narrow Logs/Caches locations. The denied container root is traversed
    /// only through SafetyGate's dedicated inspection API; it is never emitted as a row.
    private func groupContainerLeaves(
        under root: String,
        whitelist: Set<String>,
        activeScopes: [GuardedScope]
    ) -> [String] {
        guard SafetyGate.isAllowedToTraverse(path: root, whitelist: whitelist) else { return [] }
        let eligibleRoots = ["Logs", "Library/Logs", "Caches", "Library/Caches"]
        var leaves: [String] = []

        for container in children(of: root).sorted() {
            if Task.isCancelled || leaves.count >= Self.rowCap { break }
            let identifier = (container as NSString).lastPathComponent.lowercased()
            guard !isAppleOwnedContainer(identifier),
                  isPlainDirectory(container),
                  SafetyGate.isAllowedToTraverse(path: container, whitelist: whitelist),
                  protectedFamily(for: container, scopes: activeScopes, includeAncestors: false) == nil,
                  !isSafariExtensionContainer(container, identifier: identifier) else { continue }

            for relative in eligibleRoots {
                let cacheOrLogRoot = (container as NSString).appendingPathComponent(relative)
                guard isPlainDirectory(cacheOrLogRoot),
                      SafetyGate.isAllowedToTraverse(path: cacheOrLogRoot, whitelist: whitelist),
                      protectedFamily(for: cacheOrLogRoot, scopes: activeScopes, includeAncestors: false) == nil else { continue }

                for leaf in children(of: cacheOrLogRoot).sorted() {
                    if Task.isCancelled || leaves.count >= Self.rowCap { break }
                    guard isPlainRegularFile(leaf),
                          SafetyGate.isAllowed(path: leaf, whitelist: whitelist),
                          protectedFamily(for: leaf, scopes: activeScopes) == nil else { continue }
                    leaves.append(leaf)
                }
            }
        }
        return leaves
    }

    private func isAppleOwnedContainer(_ identifier: String) -> Bool {
        ["com.apple.", "group.com.apple.", "systemgroup.com.apple."]
            .contains(where: identifier.hasPrefix)
    }

    private func isSafariExtensionContainer(_ path: String, identifier: String) -> Bool {
        if identifier.contains("safari") { return true }
        let markers = [
            "Safari Extension", "Safari Web Extension",
            "Data/Library/Safari/Extensions",
            "Data/Library/Application Support/Safari/Extensions"
        ]
        return markers.contains {
            isPlainDirectory((path as NSString).appendingPathComponent($0))
        }
    }

    private func isPlainDirectory(_ path: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isPlainRegularFile(_ path: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    /// Profile patterns can contain wildcards in parent components, not just the filename.
    /// Expand one level at a time, bounding work and never walking a matched symlink.
    private func expandGlob(_ pattern: String, whitelist: Set<String> = [],
                            activeScopes: [GuardedScope] = []) -> (paths: [String], truncated: Bool) {
        let components = pattern.split(separator: "/").map(String.init)
        guard let firstPattern = components.firstIndex(where: { $0.contains("*") || $0.contains("?") || $0.contains("[") }) else {
            return (FileManager.default.fileExists(atPath: pattern) ? [pattern] : [], false)
        }
        var current = ["/" + components.prefix(firstPattern).joined(separator: "/")]
        var truncated = false
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        for index in firstPattern..<components.count {
            if Task.isCancelled { return ([], true) }
            let component = components[index]
            let wildcard = component.contains("*") || component.contains("?") || component.contains("[")
            var next: [String] = []
            for parent in current {
                if Task.isCancelled { return ([], true) }
                guard SafetyGate.isAllowedToTraverse(path: parent, whitelist: whitelist),
                      protectedFamily(for: parent, scopes: activeScopes, includeAncestors: false) == nil else { continue }
                let candidates = wildcard ? children(of: parent)
                    : [(parent as NSString).appendingPathComponent(component)]
                for candidate in candidates {
                    if Task.isCancelled { return ([], true) }
                    let isFinalComponent = index == components.count - 1
                    let safetyAllows = isFinalComponent
                        ? SafetyGate.isAllowed(path: candidate, whitelist: whitelist)
                        : SafetyGate.isAllowedToTraverse(path: candidate, whitelist: whitelist)
                    guard !wildcard || fnmatch(component, (candidate as NSString).lastPathComponent, FNM_PERIOD) == 0,
                          safetyAllows,
                          protectedFamily(for: candidate, scopes: activeScopes, includeAncestors: isFinalComponent) == nil,
                          let values = try? URL(fileURLWithPath: candidate).resourceValues(forKeys: keys),
                          values.isSymbolicLink != true,
                          isFinalComponent || values.isDirectory == true else { continue }
                    next.append(candidate)
                    if next.count >= Self.rowCap { truncated = true; break }
                }
                if next.count >= Self.rowCap { break }
            }
            current = next
            if current.isEmpty { break }
        }
        return (current, truncated)
    }

    private func children(of directory: String) -> [String] {
        if let directoryListing { return directoryListing(directory) }
        let url = URL(fileURLWithPath: directory)
        // Pool per directory: contentsOfDirectory autoreleases a URL for every entry.
        return autoreleasepool {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: []
            ) else { return [] }
            return entries.map(\.path)
        }
    }

    /// Chromium-style framework pruning: keep the version `Current` points at and
    /// the newest version staged after it. Missing or broken evidence keeps all.
    private func frameworkVersions(
        inApp app: String, framework: String, pruneRule: MolePruneRule?, whitelist: Set<String>
    ) -> [String] {
        guard case .keepCurrentSymlinkTarget? = pruneRule else { return [] }
        let versionsDir = "\(app)/Contents/Frameworks/\(framework)/Versions"
        guard isPlainDirectory(versionsDir),
              SafetyGate.isAllowedToTraverse(path: versionsDir, whitelist: whitelist) else { return [] }
        let currentLink = "\(versionsDir)/Current"
        guard let linkValues = try? URL(fileURLWithPath: currentLink)
                .resourceValues(forKeys: [.isSymbolicLinkKey]),
              linkValues.isSymbolicLink == true,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: currentLink),
              !destination.isEmpty else { return [] }
        let resolvedDestination = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination).standardizedFileURL.path
            : URL(fileURLWithPath: versionsDir).appendingPathComponent(destination).standardizedFileURL.path
        let currentName = (destination as NSString).lastPathComponent
        let currentPath = (versionsDir as NSString).appendingPathComponent(currentName)
        guard !currentName.isEmpty, resolvedDestination == URL(fileURLWithPath: currentPath).standardizedFileURL.path,
              isPlainDirectory(currentPath),
              let currentDate = modificationDate(currentPath) else { return [] }

        let directories = children(of: versionsDir).filter(isPlainDirectory)
        guard directories.allSatisfy({ modificationDate($0) != nil }) else { return [] }
        var keep: Set<String> = [physicalPath(currentPath)]
        if let staged = directories.compactMap({ path -> (String, Date)? in
            guard physicalPath(path) != physicalPath(currentPath),
                  let date = modificationDate(path), date > currentDate else { return nil }
            return (path, date)
        }).sorted(by: { lhs, rhs in
            lhs.1 == rhs.1
                ? (lhs.0 as NSString).lastPathComponent < (rhs.0 as NSString).lastPathComponent
                : lhs.1 > rhs.1
        }).first {
            keep.insert(physicalPath(staged.0))
        }
        return directories.filter { !keep.contains(physicalPath($0)) }
    }

    private func applyPruneRule(_ candidates: [String], rule: MolePruneRule?) -> [String] {
        guard let rule else { return candidates }
        switch rule {
        case .keepCurrentSymlinkTarget:
            // This rule is meaningful only with frameworkVersions, where Current is validated.
            return []
        case .keepNewest(let keepCount):
            let datedDirectories = candidates.compactMap { path -> (String, Date)? in
                guard isPlainDirectory(path), let date = modificationDate(path) else { return nil }
                return (path, date)
            }.sorted { lhs, rhs in
                lhs.1 == rhs.1
                    ? (lhs.0 as NSString).lastPathComponent < (rhs.0 as NSString).lastPathComponent
                    : lhs.1 > rhs.1
            }
            return datedDirectories.dropFirst(max(0, keepCount)).map(\.0)
        case .staleNumberedSegments(let minAgeDays):
            guard minAgeDays >= 0 else { return [] }
            let cutoff = Date.now.addingTimeInterval(-Double(minAgeDays) * 86_400)
            return candidates.filter { path in
                let name = (path as NSString).lastPathComponent
                guard !name.isEmpty, name.utf8.allSatisfy({ (48...57).contains($0) }),
                      isPlainDirectory(path) else { return false }
                let marker = (path as NSString).appendingPathComponent("seg.x0")
                guard let values = try? URL(fileURLWithPath: marker)
                        .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = modificationDate(marker) else { return false }
                return modified <= cutoff
            }
        case .keepInstalledOrNewerVersion:
            return updaterVersionsToPrune(candidates, home: home)
        }
    }

    private func updaterVersionsToPrune(_ candidates: [String], home: String) -> [String] {
        let directories = candidates.filter(isPlainDirectory)
        let validVersions = directories.compactMap { path -> (String, String)? in
            let name = (path as NSString).lastPathComponent
            return isNumericVersion(name) ? (path, name) : nil
        }
        guard let installed = installedEdgeVersion(home: home) else {
            guard validVersions.count > 1,
                  let newest = validVersions.map(\.1).sorted(by: versionLessThan).last else { return [] }
            return validVersions.filter { $0.1 != newest }.map(\.0)
        }
        return validVersions.filter { versionLessThan($0.1, installed) }.map(\.0)
    }

    private func installedEdgeVersion(home: String) -> String? {
        let appPaths = [
            "/Applications/Microsoft Edge.app/Contents/Info.plist",
            (home as NSString).appendingPathComponent("Applications/Microsoft Edge.app/Contents/Info.plist")
        ]
        for path in appPaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = plist as? [String: Any],
                  let version = dictionary["CFBundleShortVersionString"] as? String,
                  isNumericVersion(version) else { continue }
            return version
        }
        return nil
    }

    private func isNumericVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) })
        }
    }

    private func versionLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric, locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending
    }

    private func physicalPath(_ path: String) -> String {
        SafetyGate.normalized(URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private func modificationDate(_ path: String) -> Date? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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

    /// Used again at removal, with a fresh process inventory from the main actor.
    public func runningProtectionReason(for path: String,
                                        targets: [CleanTarget] = MoleTables.allTargets) -> String? {
        protectedFamily(for: path, scopes: guardedScopes(in: targets))?.message
    }

    public func runningProtectionReasons(for paths: [String],
                                         targets: [CleanTarget] = MoleTables.allTargets) -> [String: String] {
        let scopes = guardedScopes(in: targets)
        var reasons: [String: String] = [:]
        for path in paths {
            if let block = protectedFamily(for: path, scopes: scopes) { reasons[path] = block.message }
        }
        return reasons
    }

    /// Revalidates the exact rule expansion and current filesystem/process/activity
    /// evidence before a selected Mole row reaches the removal boundary.
    public func removalProtectionReason(
        for path: String,
        ruleID: String,
        whitelist: Set<String>,
        targets: [CleanTarget] = MoleTables.allTargets
    ) async -> String? {
        guard let target = targets.first(where: { $0.ruleID == ruleID }) else {
            return "The Mole cleanup rule could not be matched; item kept."
        }
        guard target.eligibility != .unsupported, !target.needsAdmin, !target.reportOnly else {
            return "This Mole rule is not removable by Tebo; item kept."
        }
        guard SafetyGate.isAllowed(path: path, whitelist: whitelist) else {
            return "Safety protections or the current whitelist block this path; item kept."
        }
        if let block = blockedByRunningProcess(target) { return block.message }
        if let block = protectedFamily(for: path, scopes: guardedScopes(in: targets)) { return block.message }
        // Mole brackets the booted-device probe between two process checks
        // (_probe_simulator_activity): the probe can take seconds, long enough
        // for a build to start, so process state is verified again after it.
        if target.processGuard?.probesBootedSimulator == true {
            switch await simulatorActivityProbe() {
            case .idle:
                break
            case .active:
                return "A simulator is booted. Shut it down and retry."
            case .unknown:
                return "Simulator activity could not be verified; item kept."
            }
            if let inventoryRefresh, let refreshed = await inventoryRefresh(),
               let block = blockedByRunningProcess(target, names: refreshed.names, paths: refreshed.executablePaths) {
                return block.message
            }
        }
        let ruleContract = contract(for: target)
        if let activityReason = await activityReason(for: path, timeout: ruleContract.budget.activityProbeTimeout) {
            return activityReason
        }

        let resolved = MolePathResolver.resolve(target.path, home: home)
        if target.kind.requiresExistingLiteralPath && !FileManager.default.fileExists(atPath: resolved) {
            return "The rule's source location no longer exists; item kept."
        }
        let candidates: [String]
        if case .glob = target.kind {
            candidates = expandGlobTarget(resolved, pruneRule: target.pruneRule,
                whitelist: whitelist, activeScopes: guardedScopes(in: targets)).paths
        } else {
            candidates = expand(target, resolved: resolved, whitelist: whitelist,
                                activeScopes: guardedScopes(in: targets))
        }
        func pathForms(_ candidate: String) -> Set<String> {
            let url = URL(fileURLWithPath: candidate)
            return Set([
                SafetyGate.normalized(url.standardizedFileURL.path),
                SafetyGate.normalized(url.resolvingSymlinksInPath().path)
            ])
        }
        let requestedForms = pathForms(path)
        guard candidates.contains(where: { !pathForms($0).isDisjoint(with: requestedForms) }) else {
            return "This path is not in the rule's current eligible expansion; item kept."
        }

        let measured = FileTreeMeasurement.read(URL(fileURLWithPath: path),
            entryLimit: ruleContract.budget.entryLimit, timeout: ruleContract.budget.measurementTimeout,
            stopAtSafetyEvidence: true, whitelist: whitelist,
            policy: ruleContract.evidencePolicy, containmentRoot: ruleContract.containmentRoot)
        if let protectedPath = measured.protectedPath {
            return "Protected data at \(protectedPath) requires retaining this item."
        }
        if measured.containsRepository { return "Repository metadata is present; item kept." }
        if measured.containsCredentials { return "Credential material is present; item kept." }
        if measured.containsSymbolicLinks { return "A symbolic link is present; item kept." }
        if measured.containsCloudPlaceholders { return "An offline/cloud placeholder is present; item kept." }
        guard measured.status == .complete, measured.bytes > 0 else {
            return "Current safety or measurement evidence is incomplete; item kept."
        }
        return nil
    }

    private func guardedScopes(in targets: [CleanTarget]) -> [GuardedScope] {
        let physicalHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        return targets.flatMap { target -> [GuardedScope] in
            guard let block = blockedByRunningProcess(target) else { return [] }
            let literal = MolePathResolver.resolve(target.path, home: home)
            let normalized = MolePathResolver.resolve(target.path, home: physicalHome)
            let parts = normalized.split(separator: "/").map(String.init)
            let firstPattern = parts.firstIndex { $0.contains("*") || $0.contains("?") || $0.contains("[") }
            let prefixCount = firstPattern ?? max(0, parts.count - 1)
            let prefix = "/" + parts.prefix(prefixCount).joined(separator: "/")
            let physicalPrefix = URL(fileURLWithPath: prefix).resolvingSymlinksInPath().path
            let physical = (physicalPrefix as NSString).appendingPathComponent(parts.dropFirst(prefixCount).joined(separator: "/"))
            let forms = [literal, normalized, physical].flatMap { path -> [String] in
                let components = path.split(separator: "/").map(String.init)
                guard let index = components.indices.first(where: {
                    $0 > 0 && components[$0 - 1].lowercased() == "library"
                        && ["containers", "group containers"].contains(components[$0].lowercased())
                }), components.count > index + 1 else { return [path] }
                let identifier = components[index + 1]
                guard !identifier.contains(where: { "*?[".contains($0) }) else { return [path] }
                return [path, "/" + components.prefix(index + 2).joined(separator: "/")]
            }
            var seen: Set<String> = []
            return forms.filter { seen.insert($0).inserted }
                .map { GuardedScope(pattern: $0, block: block) }
        }
    }

    private func protectedFamily(for path: String, scopes: [GuardedScope], includeAncestors: Bool = true) -> ProcessGuardBlock? {
        guard !scopes.isEmpty else { return nil }
        let physical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for form in [path, physical] {
            let candidate = form.lowercased().split(separator: "/").map(String.init)
            for scope in scopes {
                let pattern = scope.pattern.lowercased().split(separator: "/").map(String.init)
                if !includeAncestors, candidate.count < pattern.count { continue }
                let overlap = min(candidate.count, pattern.count)
                // A candidate below a guarded location or a parent containing it must both be kept.
                if overlap > 0, zip(pattern.prefix(overlap), candidate.prefix(overlap)).allSatisfy({
                    fnmatch($0.0, $0.1, FNM_PERIOD) == 0
                }) { return scope.block }
            }
        }
        return nil
    }

    /// Why this target must wait, or nil when it is clear to clean.
    private func blockedByRunningProcess(_ target: CleanTarget) -> ProcessGuardBlock? {
        blockedByRunningProcess(target, names: runningProcessNames, paths: runningProcessPaths)
    }

    /// Same check against an explicitly supplied inventory, used by the removal
    /// bracket with a freshly fetched one.
    private func blockedByRunningProcess(
        _ target: CleanTarget, names: Set<String>?, paths: Set<String>?
    ) -> ProcessGuardBlock? {
        guard let guardSpec = target.processGuard else { return nil }
        let exactNames = guardSpec.exactProcessNames.map { $0.lowercased() }
        if !exactNames.isEmpty {
            guard let names else { return .unknown(guardSpec.family) }
            if exactNames.contains(where: names.contains) { return .active(guardSpec.family) }
        }
        let pathSubstrings = guardSpec.pathSubstrings.map { $0.lowercased() }
        if !pathSubstrings.isEmpty {
            guard let paths else { return .unknown(guardSpec.family) }
            if paths.contains(where: { path in
                pathSubstrings.contains(where: path.contains)
            }) { return .active(guardSpec.family) }
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
        if target.eligibility == .manualReview || target.risk == .review {
            text = "Review first: \(text)"
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
        case .directorySweep, .glob, .findRule, .groupContainerLeaves: return true
        case .directory, .file, .frameworkVersions: return false
        }
    }

    /// False only for wildcard rows, whose table path is a pattern rather than a real location.
    var requiresExistingLiteralPath: Bool {
        if case .glob = self { return false }
        return true
    }
}

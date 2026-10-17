import Foundation

/// Immutable evidence captured when the user opens a Mole removal confirmation.
/// A changed result set, selection, scan scope, protection policy or preview proof
/// invalidates the dialog rather than broadening the operation.
struct MoleRemovalReview: Sendable {
    let rows: [ScanResult]
    let selectedIDs: Set<UUID>
    let scanScope: [String]?
    let whitelist: Set<String>
    let identitiesByPath: [String: FileIdentity]
    let bindingsByPath: [String: PathBinding]

    func refusalReason(
        currentRows: [ScanResult],
        currentSelectedIDs: Set<UUID>,
        currentScope: [String]?,
        currentWhitelist: Set<String>,
        currentIdentitiesByPath: [String: FileIdentity],
        currentBindingsByPath: [String: PathBinding],
        previewEnabled: Bool
    ) -> String? {
        guard !rows.isEmpty, !selectedIDs.isEmpty else {
            return "Select reviewed items before moving anything to the Trash."
        }
        let rowIDs = Set(rows.map(\.id))
        guard rowIDs.count == rows.count, selectedIDs.isSubset(of: rowIDs),
              selectedIDs == Set(rows.filter { selectedIDs.contains($0.id) }.map(\.id)) else {
            return "The reviewed result set is invalid; scan again before removal."
        }
        let selectedRows = rows.filter { selectedIDs.contains($0.id) }
        guard Set(selectedRows.map(\.path)).count == selectedRows.count else {
            return "The selection contains duplicate paths; scan again before removal."
        }
        guard !previewEnabled else { return "Preview is on; nothing was moved." }
        guard currentRows.count == rows.count, Set(currentRows) == Set(rows) else {
            return "Scan results changed after review; rescan and confirm again."
        }
        guard currentSelectedIDs == selectedIDs else {
            return "Selection changed after review; confirm the current selection again."
        }
        guard currentScope == scanScope else {
            return "Scan settings changed after review; rescan before removal."
        }
        guard currentWhitelist == whitelist else {
            return "Protection settings changed after review; rescan before removal."
        }
        for row in selectedRows {
            guard let identity = identitiesByPath[row.path],
                  let binding = bindingsByPath[row.path], binding.leaf == identity else {
                return "Preview identity or physical-parent binding is missing; rescan before removal."
            }
            guard currentIdentitiesByPath[row.path] == identity,
                  currentBindingsByPath[row.path] == binding,
                  PathBinding.read(path: row.path) == binding else {
                return "Preview identity or physical parent changed; rescan before removal."
            }
        }
        return nil
    }
}

/// Dispatches final Mole validation to the exact scanner/rule that produced a row.
/// The caller still sends successful evidence through DeletePipeline, which performs
/// path, identity, binding, activity and Trash-only checks immediately before mutation.
struct CleanupRemovalValidator: Sendable {
    private let moleTargets: [CleanTarget]
    private let home: String
    private let orphanConfiguration: OrphanScanConfiguration
    private let orphanBundleLookup: any BundleLookup
    private let installerConfiguration: InstallerScanConfiguration
    private let projectRoots: [String]
    private let maintenanceRunningIDsProvider: (@Sendable () async -> Set<String>?)?
    private let processInventoryProvider: (@Sendable () async -> MoleProcessInventory?)?

    init(
        moleTargets: [CleanTarget] = MoleTables.allTargets,
        home: String = NSHomeDirectory(),
        orphanConfiguration: OrphanScanConfiguration = .defaults(),
        orphanBundleLookup: (any BundleLookup)? = nil,
        installerConfiguration: InstallerScanConfiguration = .defaults(),
        projectRoots: [String] = MolePaths.projectSearchRoots,
        maintenanceRunningIDsProvider: (@Sendable () async -> Set<String>?)? = nil,
        processInventoryProvider: (@Sendable () async -> MoleProcessInventory?)? = nil
    ) {
        self.moleTargets = moleTargets
        self.home = home
        self.orphanConfiguration = orphanConfiguration
        self.orphanBundleLookup = orphanBundleLookup
            ?? InstalledAppsBundleLookup(appRoots: orphanConfiguration.applicationRoots)
        self.installerConfiguration = installerConfiguration
        self.projectRoots = projectRoots
        self.maintenanceRunningIDsProvider = maintenanceRunningIDsProvider
        self.processInventoryProvider = processInventoryProvider
    }

    /// Returns a refusal reason, or nil only while the row's actual producing rule
    /// still recognizes this exact path under the fresh policy and configured roots.
    func protectionReason(for row: ScanResult, whitelist: Set<String>) async -> String? {
        guard !Task.isCancelled else { return "Removal cancelled before validation." }
        switch row.cleanupSource {
        case .moleRule(let ruleID):
            let provider: @Sendable () async -> MoleProcessInventory?
            if let processInventoryProvider { provider = processInventoryProvider }
            else { provider = { await MainActor.run { TargetScanner.liveProcessInventory() } } }
            let inventory = await provider()
            // The provider doubles as the removal bracket's refresh hook: the
            // booted-simulator probe re-verifies process state after itself.
            let scanner = TargetScanner(home: home, processInventory: inventory, inventoryRefresh: provider)
            return await scanner.removalProtectionReason(
                for: row.path, ruleID: ruleID, whitelist: whitelist, targets: moleTargets
            )

        case .orphanCache(let owner):
            guard URL(fileURLWithPath: row.path).lastPathComponent == owner else {
                return "Orphan source does not match this cache owner; item kept."
            }
            return await OrphanScanner(configuration: orphanConfiguration, bundleLookup: orphanBundleLookup)
                .removalProtectionReason(for: row.path, whitelist: whitelist)

        case .installer:
            return await InstallerFinder(configuration: installerConfiguration)
                .removalProtectionReason(for: row.path, whitelist: whitelist)

        case .projectArtifact:
            return await ProjectArtifactScanner(roots: projectRoots)
                .protectionReason(for: URL(fileURLWithPath: row.path), whitelist: whitelist)

        case .maintenance(let rawValue):
            guard let mode = MaintenanceScan.allCases.first(where: { $0.rawValue == rawValue }) else {
                return "Maintenance source is not recognized; item kept."
            }
            let runningIDs: Set<String>?
            if let maintenanceRunningIDsProvider {
                runningIDs = await maintenanceRunningIDsProvider()
            } else {
                runningIDs = await MainActor.run { TargetScanner.liveProcessInventory()?.names }
            }
            return MaintenanceScanner(home: home).removalReason(
                path: row.path, mode: mode, whitelist: whitelist, runningIDs: runningIDs
            )

        case nil:
            return "Cleanup source evidence is missing; rescan before removal."
        }
    }

    /// Analyze is deliberate manual selection, not a recommended cleanup rule.
    /// Keep the same current path protections and native open-handle guard, but do
    /// not invent a source rule or grant the row a safe-default recommendation.
    static func manualAnalyzeProtectionReason(for path: String, whitelist: Set<String>) async -> String? {
        guard !Task.isCancelled else { return "Removal cancelled before validation." }
        if let reason = PathValidator.validate(path: path, whitelist: whitelist) {
            return reason.rawValue
        }
        if let reason = await CleanupActivityGuard.reason(for: path) { return reason }
        // Manual selection cannot authorize a parent that silently includes protected descendants.
        let measured = FileTreeMeasurement.read(URL(fileURLWithPath: path), stopAtSafetyEvidence: true, whitelist: whitelist)
        guard measured.status == .complete, measured.protectedPath == nil,
              !measured.containsRepository, !measured.containsCredentials else {
            return "Protected descendants or incomplete safety evidence; item kept."
        }
        return nil
    }
}

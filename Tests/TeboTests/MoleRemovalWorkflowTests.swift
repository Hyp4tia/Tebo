import Foundation
import Testing
@testable import Tebo

@Suite("Mole removal workflow")
struct MoleRemovalWorkflowTests {
    @Test("Enabled Chrome rules reach their real final validator with exact provenance",
          arguments: ["Chrome code cache", "Chrome GPU cache"])
    func enabledChromeRuleUsesFinalValidator(label: String) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relative = label == "Chrome code cache" ? "Code Cache/js" : "GPUCache"
        let directory = fixture.root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/\(relative)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("generated cache fixture".utf8).write(to: directory.appendingPathComponent("cache.bin"))
        let target = try #require(Browsers.all.first { $0.label == label })
        let idle = MoleProcessInventory(names: [], executablePaths: [])
        let outcome = await TargetScanner(home: fixture.root.path, processInventory: idle)
            .scan(targets: [target], whitelist: [])
        let row = try #require(outcome.deletable.first)
        #expect(row.recommendedForSelection)
        #expect(row.cleanupSource == .moleRule(target.ruleID))
        let validator = CleanupRemovalValidator(moleTargets: [target], home: fixture.root.path,
            processInventoryProvider: { idle })
        #expect(await validator.protectionReason(for: row, whitelist: []) == nil)
        #expect(await validator.protectionReason(for: row, whitelist: [row.path]) != nil)
        let active = CleanupRemovalValidator(moleTargets: [target], home: fixture.root.path,
            processInventoryProvider: { MoleProcessInventory(names: ["Google Chrome Helper"], executablePaths: []) })
        #expect(await active.protectionReason(for: row, whitelist: []) != nil)
    }

    @Test("Settled Mole outcomes leave selection and kept rows become read-only advisories")
    @MainActor
    func settledMoleOutcomesBecomeReadOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = AppState(whitelistURL: fixture.marker)
        let rows = (0..<4).map { index in
            ScanResult(path: fixture.root.appendingPathComponent("\(index).bin").path,
                       sizeBytes: 1, category: "Fixture", reason: "Fixture")
        }
        let other = ScanResult(path: fixture.root.appendingPathComponent("other.bin").path,
                               sizeBytes: 1, category: "Fixture", reason: "Fixture")
        state.resultsByTab["clean"] = rows
        state.resultsByTab["duplicates"] = [other]
        state.selectAll(for: "clean")
        state.select([other.id])
        let report = DeleteReport(outcomes: [
            .init(path: rows[0].path, result: .trashed(bytes: 1)),
            .init(path: rows[1].path, result: .skipped(reason: .missing)),
            .init(path: rows[2].path, result: .failed(message: "Fixture filesystem error"))
        ])
        let settled = state.applyMoleRemoval(report, to: "clean")
        #expect(settled == Set(rows.prefix(3).map(\.path)))
        #expect(state.results(for: "clean") == [rows[3]])
        #expect(state.selectedIDs == [rows[3].id, other.id])
        #expect(Set(state.advisories(for: "clean").map(\.id)) == [rows[1].path, rows[2].path])
        #expect(state.advisories(for: "clean").contains { $0.detail.contains("Fixture filesystem error") })
    }

    @Test("A Mole safety refusal is kept, not counted as a Trash failure")
    func safetyRefusalIsSkipped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let item = fixture.root.appendingPathComponent("cache.bin")
        try Data("fixture cache".utf8).write(to: item)
        let binding = try #require(PathBinding.read(path: item.path))
        let report = await DeletePipeline().trash(paths: [item.path], whitelist: [],
            expectedIdentities: [item.path: binding.leaf], expectedBindings: [item.path: binding],
            requirePreviewIdentity: true, protectionURL: fixture.marker,
            additionalValidation: { _ in "Current owner activity could not be verified." })
        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(report.failedCount == 0)
        #expect(FileManager.default.fileExists(atPath: item.path))
    }

    @Test("Manual Analyze cannot remove a parent containing mandatory protected data")
    func manualAnalysisKeepsProtectedDescendants() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = fixture.root.appendingPathComponent("cache")
        let model = cache.appendingPathComponent("model.mlmodelc/weights.bin")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("protected fixture model".utf8).write(to: model)
        #expect(await CleanupRemovalValidator.manualAnalyzeProtectionReason(for: cache.path, whitelist: []) != nil)
    }

    @Test("A preview-bound Mole review accepts only the exact current rows and evidence")
    func reviewRequiresExactCurrentSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let item = fixture.root.appendingPathComponent("cache.bin")
        try Data("reviewed cache".utf8).write(to: item)
        let identity = try #require(FileIdentity.read(path: item.path))
        let binding = try #require(PathBinding.read(path: item.path))
        let row = ScanResult(path: item.path, sizeBytes: 14, category: "Cache", reason: "Reviewed",
                             cleanupSource: .moleRule("fixture.rule"))
        let review = MoleRemovalReview(rows: [row], selectedIDs: [row.id], scanScope: [fixture.root.path],
                                       whitelist: [], identitiesByPath: [item.path: identity],
                                       bindingsByPath: [item.path: binding])

        #expect(review.refusalReason(currentRows: [row], currentSelectedIDs: [row.id],
            currentScope: [fixture.root.path], currentWhitelist: [],
            currentIdentitiesByPath: [item.path: identity], currentBindingsByPath: [item.path: binding],
            previewEnabled: false) == nil)
        #expect(review.refusalReason(currentRows: [row], currentSelectedIDs: [],
            currentScope: [fixture.root.path], currentWhitelist: [],
            currentIdentitiesByPath: [item.path: identity], currentBindingsByPath: [item.path: binding],
            previewEnabled: false) != nil)
        let changedRow = ScanResult(id: row.id, path: row.path, sizeBytes: row.sizeBytes + 1,
                                    category: row.category, reason: row.reason,
                                    cleanupSource: row.cleanupSource)
        #expect(review.refusalReason(currentRows: [changedRow], currentSelectedIDs: [row.id],
            currentScope: [fixture.root.path], currentWhitelist: [],
            currentIdentitiesByPath: [item.path: identity], currentBindingsByPath: [item.path: binding],
            previewEnabled: false) != nil)
        #expect(review.refusalReason(currentRows: [row], currentSelectedIDs: [row.id],
            currentScope: [fixture.root.appendingPathComponent("changed").path], currentWhitelist: [],
            currentIdentitiesByPath: [item.path: identity], currentBindingsByPath: [item.path: binding],
            previewEnabled: false) != nil)
        #expect(review.refusalReason(currentRows: [row], currentSelectedIDs: [row.id],
            currentScope: [fixture.root.path], currentWhitelist: ["cache"],
            currentIdentitiesByPath: [item.path: identity], currentBindingsByPath: [item.path: binding],
            previewEnabled: false) != nil)
        #expect(review.refusalReason(currentRows: [row], currentSelectedIDs: [row.id],
            currentScope: [fixture.root.path], currentWhitelist: [],
            currentIdentitiesByPath: [:], currentBindingsByPath: [item.path: binding],
            previewEnabled: false) != nil)
        #expect(review.refusalReason(currentRows: [row], currentSelectedIDs: [row.id],
            currentScope: [fixture.root.path], currentWhitelist: [],
            currentIdentitiesByPath: [item.path: identity], currentBindingsByPath: [:],
            previewEnabled: false) != nil)
        #expect(review.refusalReason(currentRows: [row], currentSelectedIDs: [row.id],
            currentScope: [fixture.root.path], currentWhitelist: [],
            currentIdentitiesByPath: [item.path: identity], currentBindingsByPath: [item.path: binding],
            previewEnabled: true) != nil)
    }

    @Test("The producing installer validator accepts current fixture evidence")
    func installerSourceUsesConfiguredFinalValidator() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let downloads = fixture.root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let installer = downloads.appendingPathComponent("fixture.dmg")
        try Data("installer payload".utf8).write(to: installer)
        let configuration = InstallerScanConfiguration(searchRoots: [downloads.path], maxDepth: 1)
        let validator = CleanupRemovalValidator(installerConfiguration: configuration,
                                               projectRoots: [fixture.root.path])
        let row = ScanResult(path: installer.path, sizeBytes: 17, category: "Downloaded Installers",
                             reason: "Fixture installer", cleanupSource: .installer)

        #expect(await validator.protectionReason(for: row, whitelist: []) == nil)
        #expect(await validator.protectionReason(for: row, whitelist: [installer.path]) != nil)
    }

    @Test("Mole rows are revalidated against their exact producing rule and current whitelist")
    func moleSourceUsesExactCurrentRule() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cache = fixture.root.appendingPathComponent("Library/Caches/org.fixture.cache", isDirectory: true)
        let leaf = cache.appendingPathComponent("eligible.bin")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("generated fixture cache".utf8).write(to: leaf)
        let target = CleanTarget(label: "Fixture cache", group: .appCaches,
                                 path: .homeRelative("Library/Caches/org.fixture.cache"),
                                 kind: .directorySweep, risk: .review, eligibility: .manualReview,
                                 explanation: "Generated fixture only", source: "fixture")
        let validator = CleanupRemovalValidator(moleTargets: [target], home: fixture.root.path,
                                                projectRoots: [fixture.root.path])
        let row = ScanResult(path: leaf.path, sizeBytes: 23, category: "Cache", reason: "Fixture",
                             cleanupSource: .moleRule(target.ruleID))
        let unknownRule = ScanResult(path: leaf.path, sizeBytes: 23, category: "Cache", reason: "Fixture",
                                     cleanupSource: .moleRule("mole:not-the-producing-rule"))

        #expect(await validator.protectionReason(for: row, whitelist: []) == nil)
        #expect(await validator.protectionReason(for: row, whitelist: [leaf.path]) != nil)
        #expect(await validator.protectionReason(for: unknownRule, whitelist: []) != nil)
    }

    @Test("Orphan-cache rows use configured roots, owner provenance and a fresh lookup")
    func orphanSourceUsesConfiguredFreshValidator() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let caches = fixture.root.appendingPathComponent("Library/Caches", isDirectory: true)
        let apps = fixture.root.appendingPathComponent("Applications", isDirectory: true)
        let cache = caches.appendingPathComponent("com.fixture.cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let leaf = cache.appendingPathComponent("cache.bin")
        try Data("rebuildable fixture cache".utf8).write(to: leaf)
        let configuration = OrphanScanConfiguration(
            applicationSupportRoots: [], cacheRoots: [caches.path], preferenceRoots: [],
            launchAgentRoots: [], applicationRoots: [apps.path], minimumOrphanAge: 0,
            rebuildableCacheBundleIDs: ["com.fixture.cache"]
        )
        let validator = CleanupRemovalValidator(
            home: fixture.root.path, orphanConfiguration: configuration,
            orphanBundleLookup: NotInstalledBundleLookup(), projectRoots: [fixture.root.path]
        )
        let row = ScanResult(path: cache.path, sizeBytes: 26, category: "Orphan cache", reason: "Fixture",
                             cleanupSource: .orphanCache("com.fixture.cache"))
        let wrongOwner = ScanResult(path: cache.path, sizeBytes: 26, category: "Orphan cache", reason: "Fixture",
                                    cleanupSource: .orphanCache("different.owner"))

        #expect(await validator.protectionReason(for: row, whitelist: []) == nil)
        #expect(await validator.protectionReason(for: row, whitelist: [cache.path]) != nil)
        #expect(await validator.protectionReason(for: wrongOwner, whitelist: []) != nil)
    }

    @Test("Maintenance rows are dispatched by exact mode and stay behind current protections")
    func maintenanceSourceUsesCurrentManualValidator() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.root.appendingPathComponent("Library/Saved Application State", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let savedState = directory.appendingPathComponent("org.fixture.State.savedState")
        try Data("possible unsaved document state".utf8).write(to: savedState)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-40 * 24 * 60 * 60)],
            ofItemAtPath: savedState.path
        )
        let validator = CleanupRemovalValidator(
            home: fixture.root.path, projectRoots: [fixture.root.path],
            maintenanceRunningIDsProvider: { Set<String>() }
        )
        let unknownProcessValidator = CleanupRemovalValidator(
            home: fixture.root.path, projectRoots: [fixture.root.path],
            maintenanceRunningIDsProvider: { nil }
        )
        let row = ScanResult(path: savedState.path, sizeBytes: 31, category: MaintenanceScan.savedStates.rawValue,
                             reason: "May contain unsaved work", cleanupSource: .maintenance(MaintenanceScan.savedStates.rawValue))
        let unknownMode = ScanResult(path: savedState.path, sizeBytes: 31, category: "Maintenance",
                                     reason: "Unknown", cleanupSource: .maintenance("not-a-mode"))

        #expect(await validator.protectionReason(for: row, whitelist: []) == nil)
        #expect(await validator.protectionReason(for: row, whitelist: [savedState.path]) != nil)
        #expect(await unknownProcessValidator.protectionReason(for: row, whitelist: []) != nil)
        #expect(await validator.protectionReason(for: unknownMode, whitelist: []) != nil)
    }

    @Test("Missing, mismatched and unrecognized source evidence fail closed")
    func sourceProvenanceCannotBeBypassed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let downloads = fixture.root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let installer = downloads.appendingPathComponent("fixture.dmg")
        try Data("installer payload".utf8).write(to: installer)
        let configuration = InstallerScanConfiguration(searchRoots: [downloads.path], maxDepth: 1)
        let validator = CleanupRemovalValidator(installerConfiguration: configuration,
                                               projectRoots: [fixture.root.path])
        let missing = ScanResult(path: installer.path, sizeBytes: 17, category: "Installer", reason: "Legacy row")
        let wrongRule = ScanResult(path: installer.path, sizeBytes: 17, category: "Installer", reason: "Wrong rule",
                                   cleanupSource: .moleRule("not-a-current-rule"))
        let mismatchedOrphan = ScanResult(path: installer.path, sizeBytes: 17, category: "Installer", reason: "Wrong owner",
                                          cleanupSource: .orphanCache("another.owner"))
        let unsupportedProject = ScanResult(path: installer.path, sizeBytes: 17, category: "Installer", reason: "Unsupported",
                                            cleanupSource: .projectArtifact)

        #expect(await validator.protectionReason(for: missing, whitelist: []) != nil)
        #expect(await validator.protectionReason(for: wrongRule, whitelist: []) != nil)
        #expect(await validator.protectionReason(for: mismatchedOrphan, whitelist: []) != nil)
        #expect(await validator.protectionReason(for: unsupportedProject, whitelist: []) != nil)
    }

    @Test("A missing preview identity or parent binding cannot authorize a Mole move")
    func reviewCannotOmitPreviewProof() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let item = fixture.root.appendingPathComponent("cache.bin")
        try Data("cache".utf8).write(to: item)
        let row = ScanResult(path: item.path, sizeBytes: 5, category: "Cache", reason: "Reviewed",
                             cleanupSource: .moleRule("fixture.rule"))
        let review = MoleRemovalReview(rows: [row], selectedIDs: [row.id], scanScope: [fixture.root.path],
                                       whitelist: [], identitiesByPath: [:], bindingsByPath: [:])

        #expect(review.refusalReason(currentRows: [row], currentSelectedIDs: [row.id],
            currentScope: [fixture.root.path], currentWhitelist: [],
            currentIdentitiesByPath: [:], currentBindingsByPath: [:], previewEnabled: false) != nil)
    }

    @Test("A same-inode same-size edit invalidates the full preview binding")
    func inPlaceEditInvalidatesReview() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let item = fixture.root.appendingPathComponent("cache.bin")
        try Data("before".utf8).write(to: item)
        let identity = try #require(FileIdentity.read(path: item.path))
        let binding = try #require(PathBinding.read(path: item.path))
        let row = ScanResult(path: item.path, sizeBytes: 6, category: "Cache", reason: "Reviewed",
                             cleanupSource: .moleRule("fixture.rule"))
        let review = MoleRemovalReview(rows: [row], selectedIDs: [row.id], scanScope: [fixture.root.path],
                                       whitelist: [], identitiesByPath: [item.path: identity],
                                       bindingsByPath: [item.path: binding])

        try Data("edited".utf8).write(to: item)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)],
                                              ofItemAtPath: item.path)
        #expect(FileIdentity.read(path: item.path) == identity)
        #expect(try #require(PathBinding.read(path: item.path)) != binding)
        #expect(review.refusalReason(currentRows: [row], currentSelectedIDs: [row.id],
            currentScope: [fixture.root.path], currentWhitelist: [],
            currentIdentitiesByPath: [item.path: identity], currentBindingsByPath: [item.path: binding],
            previewEnabled: false) != nil)
    }

    private func makeFixture() throws -> (root: URL, marker: URL) {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-mole-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("fixture.marker"))
    }

    private struct NotInstalledBundleLookup: BundleLookup {
        func isInstalled(bundleID: String) async -> BundleLookupResult { .notInstalled }
        func isInstalledFresh(bundleID: String) async -> BundleLookupResult { .notInstalled }
    }
}

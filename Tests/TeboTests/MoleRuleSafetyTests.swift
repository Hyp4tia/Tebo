import Foundation
import Testing
@testable import Tebo

@Suite("MoleRuleSafety")
struct MoleRuleSafetyTests {
    @Test("Group-container cleanup only returns narrow cache or log leaves")
    func groupContainerCleanupDoesNotReturnWholeContainers() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-group-container-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let container = home.appendingPathComponent("Library/Group Containers/group.fixture.shared")
        let documents = container.appendingPathComponent("Documents/keep.txt")
        let cache = container.appendingPathComponent("Library/Caches/cache.bin")
        let log = container.appendingPathComponent("Logs/old.log")
        for file in [documents, cache, log] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: file)
        }

        let target = try #require(AppCaches.all.first { $0.label == "Group Containers cache and log leaves" })
        let outcome = await TargetScanner(home: home.path, runningProcessNames: []).scan(
            targets: [target], whitelist: []
        )

        #expect(!outcome.deletable.contains { $0.path.hasSuffix("/group.fixture.shared") })
        #expect(outcome.deletable.contains { $0.path.hasSuffix("/group.fixture.shared/Logs/old.log") }, "eligible log leaf should be surfaced; rows=\(outcome.deletable.map { $0.path }), advisories=\(outcome.advisories.map { $0.detail }), absent=\(outcome.absentLocationCount)")
        #expect(outcome.deletable.allSatisfy {
            $0.path.contains("/Logs/") || $0.path.contains("/Caches/")
        })
        #expect(!outcome.deletable.contains { $0.path.contains("/Documents/") })
    }

    @Test("Path-substring process guards match executable paths")
    func pathSubstringProcessGuardDefers() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-process-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/Caches/com.autodesk.fixture/cache.bin")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)

        let target = CleanTarget(
            label: "Autodesk cache", group: .appCaches,
            path: .homeRelative("Library/Caches/com.autodesk.fixture"),
            kind: .directorySweep, risk: .review, eligibility: .manualReview, explanation: "fixture",
            processGuard: MoleProcessGuard(family: "Autodesk", pathSubstrings: ["/Autodesk Fusion.app/Contents/MacOS/Autodesk Fusion"]),
            reportOnly: false, source: "test"
        )
        let scanner = TargetScanner(
            home: home.path,
            processInventory: MoleProcessInventory(
                names: ["different-helper"],
                executablePaths: ["/Applications/Autodesk Fusion.app/Contents/MacOS/Autodesk Fusion"]
            )
        )
        let outcome = await scanner.scan(targets: [target], whitelist: [])

        #expect(outcome.deletable.isEmpty)
        #expect(outcome.advisories.contains { $0.detail.contains("Autodesk") })
    }

    @Test("Unknown executable-path inventory withholds guarded cleanup")
    func unknownProcessPathInventoryIsNotTreatedAsIdle() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-process-unknown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/Caches/com.autodesk.fixture/cache.bin")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)

        let target = CleanTarget(
            label: "Autodesk cache", group: .appCaches,
            path: .homeRelative("Library/Caches/com.autodesk.fixture"),
            kind: .directorySweep, risk: .review, eligibility: .manualReview, explanation: "fixture",
            processGuard: MoleProcessGuard(family: "Autodesk", pathSubstrings: ["autodesk fusion.app"]),
            reportOnly: false, source: "test"
        )
        let scanner = TargetScanner(
            home: home.path,
            processInventory: MoleProcessInventory(names: [], executablePaths: nil)
        )
        let outcome = await scanner.scan(targets: [target], whitelist: [])

        #expect(outcome.deletable.isEmpty)
        #expect(outcome.advisories.contains { $0.group == "Process state unknown" })
        #expect(outcome.advisories.contains { $0.detail.contains("unknown") })
    }

    @Test("Broad cache sweeps withhold a parent that contains mandatory protected data")
    func broadCacheSweepCannotBypassNestedProtection() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-protected-descendant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let candidateRoot = home.appendingPathComponent("Library/Caches/org.fixture.cache")
        let protected = candidateRoot.appendingPathComponent("Compiled.mlmodelc/weights.bin")
        let ordinary = candidateRoot.appendingPathComponent("ordinary.cache")
        try FileManager.default.createDirectory(at: protected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model".utf8).write(to: protected)
        try Data("cache".utf8).write(to: ordinary)

        let target = CleanTarget(
            label: "Broad cache sweep", group: .appCaches,
            path: .homeRelative("Library/Caches"), kind: .directorySweep,
            eligibility: .manualReview, explanation: "fixture", reportOnly: false, source: "test"
        )
        let outcome = await TargetScanner(home: home.path, runningProcessNames: []).scan(
            targets: [target], whitelist: []
        )

        #expect(!outcome.deletable.contains { $0.path.hasSuffix("/org.fixture.cache") })
        #expect(outcome.advisories.contains { $0.detail.contains("Compiled.mlmodelc") || $0.detail.contains("protected") })
    }

    @Test("Scanner withholds files that are open during discovery")
    func openFileActivityPreventsSelectableRows() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-open-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/Caches/org.fixture.app/cache.db")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)
        let openHandle = try FileHandle(forReadingFrom: file)
        defer { try? openHandle.close() }

        let target = CleanTarget(
            label: "Fixture cache", group: .appCaches,
            path: .homeRelative("Library/Caches/org.fixture.app"), kind: .directorySweep,
            risk: .review, eligibility: .manualReview, explanation: "fixture", reportOnly: false, source: "test"
        )
        let outcome = await TargetScanner(home: home.path, runningProcessNames: []).scan(
            targets: [target], whitelist: []
        )

        #expect(!outcome.deletable.contains { $0.path.hasSuffix("/cache.db") })
        #expect(outcome.advisories.contains {
            $0.detail.contains("using this item") || $0.detail.contains("could not be verified")
        })
    }

    @Test("Every runtime Mole target has a unique stable rule id")
    func ruleIDsAreUniqueAcrossRuntimeTargets() {
        let ids = MoleTables.allTargets.map { $0.ruleID }
        #expect(ids.count == 469)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("mole:") })
    }

    @Test("Final rule reevaluation accepts only a current expansion candidate")
    func finalRuleReevaluationRechecksExactExpansion() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-final-rule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Caches/org.fixture.cache")
        let eligible = root.appendingPathComponent("eligible.bin")
        let nested = root.appendingPathComponent("nested/not-a-direct-leaf.bin")
        try FileManager.default.createDirectory(at: eligible.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("eligible".utf8).write(to: eligible)
        try Data("nested".utf8).write(to: nested)

        let target = CleanTarget(
            label: "Fixture cache", group: .appCaches,
            path: .homeRelative("Library/Caches/org.fixture.cache"), kind: .directorySweep,
            risk: .review, eligibility: .manualReview, explanation: "fixture", reportOnly: false, source: "test"
        )
        let scanner = TargetScanner(
            home: home.path,
            processInventory: MoleProcessInventory(names: [], executablePaths: [])
        )
        let eligiblePath = eligible.resolvingSymlinksInPath().path
        let nestedPath = nested.resolvingSymlinksInPath().path
        let eligibleReason = await scanner.removalProtectionReason(
            for: eligiblePath, ruleID: target.ruleID, whitelist: [], targets: [target]
        )
        let nestedReason = await scanner.removalProtectionReason(
            for: nestedPath, ruleID: target.ruleID, whitelist: [], targets: [target]
        )
        let unknownRuleReason = await scanner.removalProtectionReason(
            for: eligiblePath, ruleID: "mole:unknown", whitelist: [], targets: [target]
        )

        #expect(eligibleReason == nil)
        #expect(nestedReason != nil)
        #expect(unknownRuleReason != nil)
    }

    @Test("Glob expansion traverses data-container roots but emits only allowed leaves")
    func globTraversesContainerRootWithoutOfferingIt() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-container-glob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Containers/org.fixture.App/Data/Library/Caches/cache.bin")
        let document = home.appendingPathComponent("Library/Containers/org.fixture.App/Data/Documents/keep.txt")
        for file in [cache, document] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        let target = CleanTarget(
            label: "Fixture sandbox cache", group: .appCaches,
            path: .homeRelative("Library/Containers/*/Data/Library/Caches/*"),
            kind: .glob, risk: .review, eligibility: .manualReview, explanation: "fixture", reportOnly: false, source: "test"
        )
        let outcome = await TargetScanner(
            home: home.path,
            processInventory: MoleProcessInventory(names: [], executablePaths: [])
        ).scan(targets: [target], whitelist: [])

        #expect(outcome.deletable.contains { $0.path.hasSuffix("/cache.bin") })
        #expect(!outcome.deletable.contains { $0.path.hasSuffix("/org.fixture.App") })
        #expect(!outcome.deletable.contains { $0.path.hasSuffix("/keep.txt") })
    }

    @Test("Broad cache sweeps withhold directories containing nested symlinks")
    func nestedSymlinksMakeCleanupReadOnly() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-nested-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let candidateRoot = home.appendingPathComponent("Library/Caches/org.fixture.cache")
        let outside = home.appendingPathComponent("outside/keep.bin")
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: candidateRoot.appendingPathComponent("ordinary.cache"))
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: candidateRoot.appendingPathComponent("linked-data"), withDestinationURL: outside
        )

        let target = CleanTarget(
            label: "Broad cache sweep", group: .appCaches,
            path: .homeRelative("Library/Caches"), kind: .directorySweep,
            eligibility: .manualReview, explanation: "fixture", reportOnly: false, source: "test"
        )
        let outcome = await TargetScanner(
            home: home.path,
            processInventory: MoleProcessInventory(names: [], executablePaths: [])
        ).scan(targets: [target], whitelist: [])

        #expect(!outcome.deletable.contains { $0.path.hasSuffix("/org.fixture.cache") })
        #expect(outcome.advisories.contains { $0.detail.localizedCaseInsensitiveContains("symbolic link") })
    }

    @Test("keepNewest retains the newest siblings and exposes only older directories")
    func keepNewestPruneSelectsOnlyOldSiblings() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-newest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Caches/versions")
        let now = Date()
        for (name, ageDays) in [("old", 30.0), ("middle", 20.0), ("new", 10.0)] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: directory.appendingPathComponent("payload.bin"))
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-ageDays * 86_400)],
                ofItemAtPath: directory.path
            )
        }
        let target = CleanTarget(
            label: "Version cache", group: .developerTools,
            path: .homeRelative("Library/Caches/versions"), kind: .directorySweep,
            risk: .review, eligibility: .manualReview, explanation: "fixture", pruneRule: .keepNewest(keepCount: 2),
            reportOnly: false, source: "test"
        )
        let outcome = await TargetScanner(
            home: home.path, processInventory: MoleProcessInventory(names: [], executablePaths: [])
        ).scan(targets: [target], whitelist: [])

        #expect(Set(outcome.deletable.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["old"])
    }

    @Test("stale numbered downloads require an old seg.x0 marker")
    func staleSegmentsRequireNumericDirectoryAndOldMarker() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-stale-segments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Application Support/segments")
        let oldDate = Date().addingTimeInterval(-31 * 86_400)
        let freshDate = Date().addingTimeInterval(-2 * 86_400)
        for name in ["123", "456", "history"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: directory.appendingPathComponent("payload.bin"))
        }
        let staleMarker = root.appendingPathComponent("123/seg.x0")
        let freshMarker = root.appendingPathComponent("456/seg.x0")
        try Data("marker".utf8).write(to: staleMarker)
        try Data("marker".utf8).write(to: freshMarker)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleMarker.path)
        try FileManager.default.setAttributes([.modificationDate: freshDate], ofItemAtPath: freshMarker.path)
        try Data("marker".utf8).write(to: root.appendingPathComponent("history/seg.x0"))

        let target = CleanTarget(
            label: "Stale segments", group: .appCaches,
            path: .homeRelative("Library/Application Support/segments"), kind: .directorySweep,
            risk: .review, eligibility: .manualReview, explanation: "fixture", pruneRule: .staleNumberedSegments(minAgeDays: 30),
            reportOnly: false, source: "test"
        )
        let outcome = await TargetScanner(
            home: home.path, processInventory: MoleProcessInventory(names: [], executablePaths: [])
        ).scan(targets: [target], whitelist: [])

        #expect(Set(outcome.deletable.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["123"])
    }

    @Test("framework pruning keeps Current and a newer staged version")
    func frameworkPruneRetainsCurrentAndNewestStaged() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-framework-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Browser.app")
        let versions = app.appendingPathComponent("Contents/Frameworks/Browser.framework/Versions")
        let now = Date()
        for (name, ageDays) in [("119", 20.0), ("120", 10.0), ("121", 1.0)] {
            let directory = versions.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: directory.appendingPathComponent("payload.bin"))
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-ageDays * 86_400)],
                ofItemAtPath: directory.path
            )
        }
        try FileManager.default.createSymbolicLink(
            at: versions.appendingPathComponent("Current"), withDestinationURL: versions.appendingPathComponent("120")
        )
        let target = CleanTarget(
            label: "Fixture browser versions", group: .browsers, path: .absolute(app.path),
            kind: .frameworkVersions(framework: "Browser.framework"), risk: .review,
            eligibility: .manualReview, explanation: "fixture", pruneRule: .keepCurrentSymlinkTarget,
            reportOnly: false, source: "test"
        )
        let outcome = await TargetScanner(
            home: home.path, processInventory: MoleProcessInventory(names: [], executablePaths: [])
        ).scan(targets: [target], whitelist: [])

        #expect(Set(outcome.deletable.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["119"])
    }

    @Test("updater pruning keeps versions equal to or newer than installed Edge")
    func updaterPruneRetainsInstalledAndNewerVersions() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-updater-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let installedInfo = home.appendingPathComponent("Applications/Microsoft Edge.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: installedInfo.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "120.0.0.0"], format: .xml, options: 0
        )
        try plist.write(to: installedInfo)
        let root = home.appendingPathComponent("Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable")
        for version in ["119.0.0.0", "120.0.0.0", "121.0.0.0"] {
            let directory = root.appendingPathComponent(version)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: directory.appendingPathComponent("payload.bin"))
        }
        let target = CleanTarget(
            label: "Edge updater versions", group: .browsers,
            path: .homeRelative("Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"),
            kind: .directorySweep, risk: .review, eligibility: .manualReview, explanation: "fixture",
            pruneRule: .keepInstalledOrNewerVersion, reportOnly: false, source: "test"
        )
        let outcome = await TargetScanner(
            home: home.path, processInventory: MoleProcessInventory(names: [], executablePaths: [])
        ).scan(targets: [target], whitelist: [])

        #expect(Set(outcome.deletable.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["119.0.0.0"])
    }

    @Test("Only explicitly supported cache tables inherit safe recommendations")
    func tablesDoNotInheritSafeDefaults() {
        let selectableSafe = MoleTables.allTargets.filter {
            $0.eligibility == .rebuildableCache && !$0.needsAdmin && !$0.reportOnly && $0.risk == .safe
        }
        #expect(Set(selectableSafe.map(\.label)) == ["Chrome code cache", "Chrome GPU cache"])
    }

    @Test("Supported Chrome caches require idle ownership and never include offline storage")
    func supportedChromeCacheHasActiveProcessGuard() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-chrome-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for relative in ["Code Cache/generated.bin", "GPUCache/shader.bin", "Service Worker/CacheStorage/offline.data"] {
            let file = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/\(relative)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("cache fixture".utf8).write(to: file)
        }
        let targets = Browsers.all.filter { $0.eligibility == .rebuildableCache }
        #expect(targets.count == 2)
        let active = await TargetScanner(
            home: home.path,
            processInventory: MoleProcessInventory(names: ["Google Chrome Helper"], executablePaths: [])
        ).scan(targets: targets, whitelist: [])
        let idle = await TargetScanner(
            home: home.path, processInventory: MoleProcessInventory(names: [], executablePaths: [])
        ).scan(targets: targets, whitelist: [])

        #expect(active.deletable.isEmpty)
        #expect(active.advisories.contains { $0.detail.contains("Chrome is running") })
        #expect(idle.deletable.count == 2)
        #expect(idle.deletable.allSatisfy { $0.recommendedForSelection })
        #expect(!idle.deletable.contains { $0.path.contains("CacheStorage") })
        let unknown = await TargetScanner(home: home.path, processInventory: nil).scan(targets: targets, whitelist: [])
        #expect(unknown.deletable.isEmpty)
    }

    @Test("The table does not authorize saved-state deletion and recent inner activity stays protected")
    func savedStateAgePolicyRetainsRecentEntries() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-saved-state-age-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Saved Application State")
        let dates: [(String, TimeInterval)] = [("com.fixture.old.savedState", 31 * 86_400),
                                               ("com.fixture.recent.savedState", 2 * 86_400)]
        for (name, age) in dates {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("state".utf8).write(to: folder.appendingPathComponent("state.plist"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: folder.path
            )
        }
        let target = try #require(AppCaches.all.first { $0.label == "Saved application states" })
        let outcome = await TargetScanner(
            home: home.path, processInventory: MoleProcessInventory(names: [], executablePaths: [])
        ).scan(targets: [target], whitelist: [])

        #expect(outcome.deletable.isEmpty)
        #expect(target.eligibility == .unsupported)
        let manual = await MaintenanceScanner(home: home.path).scan(.savedStates, whitelist: [], runningIDs: [])
        #expect(manual.rows.isEmpty)
        #expect(target.risk == .review)
    }

    @Test("Offline-sensitive and alias-dependent rules remain read-only")
    func unsupportedOfflineAndAliasRulesAreReportOnly() throws {
        let spotify = try #require(GuiApps.all.first { $0.label == "Spotify cache" })
        let autodesk = try #require(GuiApps.all.first { $0.label == "Autodesk Fusion old bundles" })
        let serviceWorkers = Browsers.all.filter { $0.label.localizedCaseInsensitiveContains("service worker") }
        let allServiceWorkersReportOnly = serviceWorkers.allSatisfy { $0.reportOnly || $0.eligibility == .unsupported }
        let allFirmwareReportOnly = Firmware.all.allSatisfy { $0.reportOnly || $0.eligibility == .unsupported }
        #expect(spotify.eligibility == .unsupported)
        #expect(autodesk.eligibility == .unsupported)
        #expect(allServiceWorkersReportOnly)
        #expect(allFirmwareReportOnly)
    }

    @Test("Container collection roots are traversable but never removable")
    func containerCollectionRootsUseTraversalOnlyPermission() {
        let roots = [
            "/Users/fixture/Library/Containers",
            "/Users/fixture/Library/Group Containers",
            "/Users/fixture/Library/Containers/org.fixture.App",
            "/Users/fixture/Library/Group Containers/group.fixture.shared"
        ]
        for root in roots {
            #expect(SafetyGate.isAllowedToTraverse(path: root, whitelist: []), "must permit inspection: \(root)")
            #expect(!SafetyGate.isAllowed(path: root, whitelist: []), "must never permit removal: \(root)")
        }
    }

    @Test("Target eligibility defaults to unsupported, independent of risk")
    func eligibilityDefaultsUnsupported() {
        let legacySafeTarget = CleanTarget(
            label: "Legacy helper row", group: .appCaches,
            path: .homeRelative("Library/Caches/legacy"), kind: .directorySweep,
            risk: .safe, explanation: "legacy fixture", source: "test"
        )
        let reviewTarget = CleanTarget(
            label: "Review row", group: .appCaches,
            path: .homeRelative("Library/Caches/review"), kind: .directorySweep,
            risk: .review, eligibility: .manualReview,
            explanation: "review fixture", source: "test"
        )

        #expect(legacySafeTarget.eligibility == .unsupported)
        #expect(reviewTarget.eligibility == .manualReview)
    }

    @Test("Glob prune rules apply both during scanning and final source validation")
    func globPruneRuleAppliesAtScanAndRemoval() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mole-glob-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Caches/versions")
        let now = Date()
        for (name, ageDays) in [("old", 30.0), ("middle", 20.0), ("new", 10.0)] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: directory.appendingPathComponent("payload.bin"))
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-ageDays * 86_400)],
                ofItemAtPath: directory.path
            )
        }
        let target = CleanTarget(
            label: "Glob versions", group: .appCaches,
            path: .homeRelative("Library/Caches/versions/*"), kind: .glob,
            eligibility: .manualReview, explanation: "fixture", pruneRule: .keepNewest(keepCount: 1), source: "test"
        )
        let scanner = TargetScanner(
            home: home.path, processInventory: MoleProcessInventory(names: [], executablePaths: [])
        )
        let outcome = await scanner.scan(targets: [target], whitelist: [])
        let retained = await scanner.removalProtectionReason(
            for: root.appendingPathComponent("new").path,
            ruleID: target.ruleID, whitelist: [], targets: [target]
        )
        let eligible = await scanner.removalProtectionReason(
            for: root.appendingPathComponent("old").path,
            ruleID: target.ruleID, whitelist: [], targets: [target]
        )

        #expect(Set(outcome.deletable.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["old", "middle"])
        #expect(retained != nil, "the newest glob match must remain outside the live eligible expansion")
        #expect(eligible == nil, "an old glob match should still be verifiably removable after review")
    }
}

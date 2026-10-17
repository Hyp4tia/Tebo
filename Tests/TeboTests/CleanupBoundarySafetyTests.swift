import Darwin
import Foundation
import Testing
@testable import Tebo

@Suite("Cleanup protection boundaries")
struct CleanupBoundarySafetyTests {
    private func normalizedPath(_ path: String) -> String {
        // Foundation enumeration can spell the same temporary location with /private/var.
        URL(fileURLWithPath: path).standardizedFileURL.path
            .replacingOccurrences(of: "/private/var/", with: "/var/")
    }

    @Test("Unknown process evidence and active bundle helpers withhold maintenance rows", arguments: [nil, "ORG.FIXTURE.EDITOR.helper"] as [String?])
    func maintenanceRequiresIdleOwner(runningName: String?) async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).resolvingSymlinksInPath()
        let root = base.appendingPathComponent("tebo-maintenance-owner-\(UUID().uuidString)")
        let file = root.appendingPathComponent("Library/Preferences/org.fixture.editor.plist")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0xff, 0xfe, 0xfd]).write(to: file)
        let running = runningName.map { Set([$0]) }
        let scanner = MaintenanceScanner(home: root.path)
        let report = await scanner.scan(.brokenPreferences, whitelist: [], runningIDs: running)
        #expect(report.rows.isEmpty)
        #expect(report.kept.contains { normalizedPath($0.id) == normalizedPath(file.path) })
        #expect(scanner.removalReason(path: file.path, mode: .brokenPreferences, whitelist: [], runningIDs: running) != nil)
    }

    @Test("Valid property lists are not offered as broken settings solely for having a non-dictionary root")
    func validPreferenceRootIsKept() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).resolvingSymlinksInPath()
        let root = base.appendingPathComponent("tebo-plist-shape-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = directory.appendingPathComponent("org.fixture.array.plist")
        let invalid = directory.appendingPathComponent("org.fixture.invalid.plist")
        try PropertyListSerialization.data(fromPropertyList: ["fixture"], format: .xml, options: 0).write(to: valid)
        try Data([0xff, 0xfe, 0xfd]).write(to: invalid)
        let scanner = MaintenanceScanner(home: root.path)
        let report = await scanner.scan(.brokenPreferences, whitelist: [], runningIDs: [])
        #expect(Set(report.rows.map { normalizedPath($0.path) }) == [normalizedPath(invalid.path)])
        #expect(scanner.removalReason(path: valid.path, mode: .brokenPreferences, whitelist: [], runningIDs: []) != nil)
    }

    @Test("Old saved application state remains manual review because it can contain unsaved work")
    func savedStateIsNeverAutomaticallyRecommended() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).resolvingSymlinksInPath()
        let root = base.appendingPathComponent("tebo-saved-state-\(UUID().uuidString)")
        let state = root.appendingPathComponent("Library/Saved Application State/org.fixture.editor.savedState")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = state.appendingPathComponent("data.data")
        try Data("unsaved fixture draft".utf8).write(to: draft)
        let old = Date.now.addingTimeInterval(-40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: draft.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: state.path)
        let report = await MaintenanceScanner(home: root.path).scan(.savedStates, whitelist: [], runningIDs: [])
        let row = try #require(report.rows.first { normalizedPath($0.path) == normalizedPath(state.path) })
        #expect(!row.recommendedForSelection)
        #expect(row.reason.localizedCaseInsensitiveContains("unsaved"))
    }

    @Test("Protected ancestors can be inspected for safe siblings but cannot be removed")
    func traversalDoesNotAuthorizeAncestorRemoval() {
        let root = "/Users/test/Library/Containers/org.fixture/Data/Library/Caches"
        #expect(SafetyGate.isAllowedToTraverse(path: root, whitelist: []))
        #expect(!SafetyGate.isAllowed(path: root, whitelist: []))
        #expect(!SafetyGate.isAllowedToTraverse(path: root + "/pypoetry/virtualenvs/project", whitelist: []))
        #expect(SafetyGate.isAllowed(path: root + "/FixtureBrowser/data.bin", whitelist: []))
        #expect(!SafetyGate.isAllowedToTraverse(path: root, whitelist: [root]))
    }

    @Test("A failed-closed global protection policy also blocks maintenance commands")
    func unknownPolicyBlocksOptimize() async {
        let task = OptimizeTask(id: "fixture_probe", title: "Fixture probe", explanation: "Fixture command",
            group: "Fixture", steps: [.init(executable: "/usr/bin/true", arguments: [])],
            needsAdmin: false, risk: .low, citation: "fixture")
        let result = await OptimizeRunner().run(task, protectedPatterns: ["/"], recordLine: { _ in })
        #expect(result == .skippedProtected)
    }

    @Test("Case aliases cannot bypass mandatory or custom protections")
    func caseAliasesAreKept() {
        #expect(!SafetyGate.isAllowed(path: "/Users/test/Library/Caches/COM.APPLE.FontRegistry/cache", whitelist: []))
        #expect(!SafetyGate.isAllowed(path: "/LIBRARY/Caches/vendor/cache", whitelist: []))
        #expect(!SafetyGate.isAllowed(path: "/Users/test/Library/Caches/KEEP.APP/cache", whitelist: ["keep.app"]))
        #expect(SafetyGate.isAllowed(path: "/Users/test/Library/Caches/OTHER.APP/cache", whitelist: ["keep.app"]))
    }

    @Test("Darwin dataless metadata never qualifies as local disposable content")
    func datalessMetadataIsKept() {
        #expect(FileTreeMeasurement.isDataless(flags: UInt32(SF_DATALESS)))
        #expect(FileTreeMeasurement.isDataless(flags: UInt32(SF_DATALESS | UF_HIDDEN)))
        #expect(!FileTreeMeasurement.isDataless(flags: 0))
        #expect(!FileTreeMeasurement.isDataless(flags: UInt32(UF_HIDDEN)))
    }

    @Test("Cleanup safety walks keep folders containing symbolic links")
    func linkedDescendantIsKept() throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-linked-tree-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("keep.bin")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("linked.bin"), withDestinationURL: target)
        #expect(FileTreeMeasurement.read(cache, stopAtSafetyEvidence: true).status != .complete)
    }

    @Test("A newly added protected descendant stops a cleanup safety walk")
    func protectedDescendantStopsSafetyWalk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-tree-\(UUID().uuidString)")
        let model = root.appendingPathComponent("cache/model.mlmodelc")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("model data".utf8).write(to: model.appendingPathComponent("weights"))
        #expect(FileTreeMeasurement.read(root.appendingPathComponent("cache"), stopAtSafetyEvidence: true).status != .complete)

        let ordinary = root.appendingPathComponent("ordinary")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: ordinary.appendingPathComponent("data.bin"))
        #expect(FileTreeMeasurement.read(ordinary, stopAtSafetyEvidence: true).status == .complete)
    }

    @Test("Mandatory protections survive an empty custom whitelist", arguments: [
        "/Users/test/Library/Caches/pypoetry/virtualenvs/project/bin/python",
        "/Users/test/Library/Caches/pypoetry",
        "/Users/test/Library/Caches/org.R-project.R/R/renv/cache/package",
        "/Users/test/Library/Caches/CloudKit/state.db",
        "/Users/test/Library/Application Support/MobileSync/Backup/device",
        "/Users/test/Pictures/Photos Library.photoslibrary/database",
        "/Users/test/Library/Caches/runtime/model.mlmodelc/weights",
        "/Users/test/Library/Group Containers/group.example.app",
        "/Users/test/Library/Containers/org.example.app",
        "/Users/test/Library/Logs/tebo/operations.log"
    ])
    func mandatoryProtections(path: String) {
        #expect(!SafetyGate.isAllowed(path: path, whitelist: []))
        #expect(SafetyGate.isAllowed(path: "/Users/test/Library/Caches/pypoetry/cache/repositories/package", whitelist: []))
        #expect(SafetyGate.isAllowed(path: "/Users/test/Library/Caches/FixtureBrowser/Cache/data", whitelist: []))
    }

    @Test("Cleanup rule provenance survives persistence without authorizing legacy rows")
    func ruleProvenanceRoundTrip() throws {
        let row = ScanResult(path: "/Users/test/Library/Caches/tool/cache.bin", sizeBytes: 10,
            category: "Cache", reason: "Supported cache leaf", cleanupSource: .moleRule("fixture.rule"))
        let decoded = try JSONDecoder().decode(ScanResult.self, from: JSONEncoder().encode(row))
        #expect(decoded.cleanupSource == .moleRule("fixture.rule"))
        let legacy = ScanResult(path: row.path, sizeBytes: 10, category: "Cache", reason: "Legacy finding")
        let legacyDecoded = try JSONDecoder().decode(ScanResult.self, from: JSONEncoder().encode(legacy))
        #expect(legacyDecoded.cleanupSource == nil)
    }

    @Test("An unreadable protection file blocks cleanup instead of loading an empty policy")
    func invalidWhitelistFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("whitelist")
        try Data([0xff, 0xfe, 0x00]).write(to: file)

        let protections = WhitelistStore.load(from: file)
        #expect(!SafetyGate.isAllowed(path: root.appendingPathComponent("cache.bin").path, whitelist: protections))
    }
}

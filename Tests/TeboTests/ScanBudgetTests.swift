import Foundation
import Testing
@testable import Tebo

// Per-rule budgets are caps, not targets: small rows finish as fast as before,
// huge tool caches get the bulk tier. These tests pin the resolution order
// (scanner override replaces the tier field it sets) and the tier threshold.

@Suite("Scan budget tiers", .serialized)
struct ScanBudgetTests {

    private let idleLsof: CleanupActivityGuard.Probe = { _, _, _ in
        BoundedProcessRunner.Result(terminationStatus: 1, stdout: "", stderr: "")
    }

    private func fixtureHome(_ prefix: String) throws -> URL {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ root: URL, _ relative: String, _ contents: String = "cache payload") throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func row(label: String, path: String, budget: MoleScanBudget) -> CleanTarget {
        CleanTarget(
            label: label, group: .developerTools, path: .homeRelative(path), kind: .directory,
            risk: .safe, eligibility: .rebuildableCache, explanation: "budget fixture",
            scanBudget: budget, source: "test"
        )
    }

    @Test("The scanner resolves each row's own tier, and an override replaces it")
    func tierResolutionAndOverride() async throws {
        let home = try fixtureHome("tebo-budget-small")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, "Library/Caches/tight/a.bin")
        try write(home, "Library/Caches/tight/b.bin")
        try write(home, "Library/Caches/roomy/a.bin")
        try write(home, "Library/Caches/roomy/b.bin")

        let tight = row(label: "tight tier", path: "Library/Caches/tight",
            budget: MoleScanBudget(entryLimit: 1, measurementTimeout: 4, activityProbeTimeout: 3))
        let roomy = row(label: "roomy tier", path: "Library/Caches/roomy",
            budget: MoleScanBudget(entryLimit: 100, measurementTimeout: 4, activityProbeTimeout: 3))
        let scanner = TargetScanner(home: home.path, runningProcessNames: [],
            simulatorActivityProbe: { .idle }, activityProbe: idleLsof)

        let outcome = await scanner.scan(targets: [tight, roomy], whitelist: [])
        #expect(outcome.deletable.count == 1)
        #expect(outcome.deletable.first?.cleanupSource == .moleRule(roomy.ruleID))
        #expect(!outcome.deletable.contains { $0.cleanupSource == .moleRule(tight.ruleID) })
        #expect(outcome.advisories.contains { $0.detail.contains("safety walk is incomplete") })

        // The scanner-level override replaces the tier's entry limit field for
        // every row, so even the roomy row comes back partial.
        let overridden = await TargetScanner(home: home.path, runningProcessNames: [],
            measurementEntryLimit: 1, simulatorActivityProbe: { .idle }, activityProbe: idleLsof)
            .scan(targets: [roomy], whitelist: [])
        #expect(overridden.deletable.isEmpty)
        #expect(!overridden.advisories.isEmpty)
    }

    @Test("Scan and removal pass the row's own open-handle probe ceiling")
    func activityTimeoutResolution() async throws {
        let home = try fixtureHome("tebo-budget-timeout")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, "Library/Caches/tight/item.bin")
        try write(home, "Library/Caches/roomy/item.bin")

        let tight = row(label: "tight probe row", path: "Library/Caches/tight",
            budget: MoleScanBudget(entryLimit: 50_000, measurementTimeout: 4, activityProbeTimeout: 3))
        let roomy = row(label: "roomy probe row", path: "Library/Caches/roomy", budget: .bulk)

        // Mirrors the Recorder pattern: the seam captures which timeout the
        // scanner handed to the lsof probe for each candidate path (the path is
        // the probe's target argument).
        final class TimeoutLog: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [String: [TimeInterval?]] = [:]
            func record(_ path: String, _ timeout: TimeInterval?) {
                lock.withLock { entries[path, default: []].append(timeout) }
            }
            var snapshot: [String: [TimeInterval?]] { lock.withLock { entries } }
        }
        let log = TimeoutLog()
        let seam: CleanupActivityGuard.Probe = { _, arguments, timeout in
            log.record(arguments.last ?? "", timeout)
            return BoundedProcessRunner.Result(terminationStatus: 1, stdout: "", stderr: "")
        }
        let scanner = TargetScanner(home: home.path, runningProcessNames: [],
            simulatorActivityProbe: { .idle }, activityProbe: seam)
        _ = await scanner.scan(targets: [tight, roomy], whitelist: [])

        let snapshot = log.snapshot
        #expect(snapshot[home.appendingPathComponent("Library/Caches/tight").path] == [3])
        let roomyPath = home.appendingPathComponent("Library/Caches/roomy").path
        #expect(snapshot[roomyPath] == [30])

        // Removal uses the same resolution: the roomy row asks for 30 seconds.
        let roomyReason = await scanner.removalProtectionReason(
            for: roomyPath, ruleID: roomy.ruleID, whitelist: [], targets: [roomy])
        #expect(roomyReason == nil)
        #expect(log.snapshot[roomyPath] == [30, 30])
    }

    @Test("A bulk-tier row completes a walk the standard tier caps", .timeLimit(.minutes(8)))
    func bulkTierCompletesPastStandardCap() async throws {
        let home = try fixtureHome("tebo-budget-bulk")
        defer { try? FileManager.default.removeItem(at: home) }
        // 250 directories x 200 one-byte files = 50,200 entries, just past the
        // standard tier's 50,000 entry cap. Files carry a byte so the rows are
        // not dropped as zero-byte noise.
        let cache = home.appendingPathComponent("Library/Caches/tebo-budget-fixture")
        let byte = Data([0x78])
        for directory in 0..<250 {
            let dir = cache.appendingPathComponent("d\(directory)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<200 {
                FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(file)").path, contents: byte)
            }
        }

        let standard = row(label: "standard tier", path: "Library/Caches/tebo-budget-fixture", budget: .standard)
        let bulk = row(label: "bulk tier", path: "Library/Caches/tebo-budget-fixture", budget: .bulk)
        let outcome = await TargetScanner(home: home.path, runningProcessNames: [],
            simulatorActivityProbe: { .idle }, activityProbe: idleLsof)
            .scan(targets: [standard, bulk], whitelist: [])

        let bulkRow = try #require(outcome.deletable.first { $0.cleanupSource == .moleRule(bulk.ruleID) },
            "rows=\(outcome.deletable.map(\.path)); advisories=\(outcome.advisories.map(\.detail))")
        #expect(bulkRow.recommendedForSelection)
        #expect(bulkRow.path.hasSuffix("tebo-budget-fixture"))
        #expect(!outcome.deletable.contains { $0.cleanupSource == .moleRule(standard.ruleID) })
        #expect(outcome.advisories.contains { $0.source.contains("tebo-budget-fixture") })
    }
}

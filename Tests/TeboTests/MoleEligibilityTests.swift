import Foundation
import Testing
@testable import Tebo

@Suite("Explicit Mole eligibility")
struct MoleEligibilityTests {
    @Test("App-bundle interior cleanup stays read-only without a signature-preservation contract")
    func sealedBundleInternalsStayReadOnly() {
        let versions = Browsers.all.filter {
            if case .frameworkVersions = $0.kind { return true }
            return false
        }
        #expect(!versions.isEmpty)
        #expect(versions.allSatisfy { $0.eligibility == .unsupported })
    }

    private func fixture() throws -> URL {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-eligibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ root: URL, _ relative: String) throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("generated cache".utf8).write(to: file)
        return file
    }

    @Test("Manual eligibility cannot inherit an automatic recommendation from risk metadata")
    func manualPolicyOverridesSafeRisk() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "cache/item.bin")
        let target = CleanTarget(label: "Manual fixture", group: .appCaches,
            path: .homeRelative("cache"), kind: .directorySweep, risk: .safe,
            eligibility: .manualReview, explanation: "Explicit fixture review", source: "fixture")
        let scanner = TargetScanner(home: root.path, runningProcessNames: [])
        let result = await scanner.scan(targets: [target], whitelist: [])
        #expect(result.deletable.count == 1)
        #expect(result.deletable.allSatisfy { !$0.recommendedForSelection })
    }

    @Test("Incomplete trees never become selectable Mole candidates")
    func partialMeasurementStaysReadOnly() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one", "two", "three"] { _ = try write(root, "cache/tree/\(name).bin") }
        let target = CleanTarget(label: "Bounded fixture", group: .appCaches,
            path: .homeRelative("cache"), kind: .directorySweep,
            eligibility: .manualReview, explanation: "Explicit fixture review", source: "fixture")
        let result = await TargetScanner(home: root.path, runningProcessNames: [], measurementEntryLimit: 1)
            .scan(targets: [target], whitelist: [])
        #expect(result.deletable.isEmpty)
        #expect(!result.advisories.isEmpty)
    }

    @Test("Unknown rules are read-only even when their risk metadata says safe")
    func unsupportedPolicyIsNotRemovable() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(root, "cache/item.bin")
        let target = CleanTarget(label: "Unsupported fixture", group: .appCaches,
            path: .homeRelative("cache"), kind: .directorySweep, risk: .safe,
            explanation: "No reviewed policy", source: "fixture")
        let scanner = TargetScanner(home: root.path, runningProcessNames: [])
        #expect(await scanner.scan(targets: [target], whitelist: []).deletable.isEmpty)
        #expect(await scanner.removalProtectionReason(for: file.path, ruleID: target.ruleID,
            whitelist: [], targets: [target]) != nil)
    }

    @Test("Glob pruning retains each sibling family's newest version at scan and removal")
    func globPruningIsConsistent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date.now.addingTimeInterval(-20 * 86_400)
        let recent = Date.now.addingTimeInterval(-10 * 86_400)
        for family in ["first", "second"] {
            for (version, date) in [("old", old), ("new", recent)] {
                _ = try write(root, "cache/\(family)/\(version)/payload.bin")
                try FileManager.default.setAttributes([.modificationDate: date],
                    ofItemAtPath: root.appendingPathComponent("cache/\(family)/\(version)").path)
            }
        }
        let target = CleanTarget(label: "Pruned fixture", group: .developerTools,
            path: .homeRelative("cache/*/*"), kind: .glob, eligibility: .manualReview,
            explanation: "Keep each family's newest", pruneRule: .keepNewest(keepCount: 1), source: "fixture")
        let scanner = TargetScanner(home: root.path, runningProcessNames: [])
        let result = await scanner.scan(targets: [target], whitelist: [])
        #expect(Set(result.deletable.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["old"])
        #expect(result.deletable.count == 2)
        for family in ["first", "second"] {
            #expect(await scanner.removalProtectionReason(for: root.appendingPathComponent("cache/\(family)/new").path,
                ruleID: target.ruleID, whitelist: [], targets: [target]) != nil)
        }
    }
}

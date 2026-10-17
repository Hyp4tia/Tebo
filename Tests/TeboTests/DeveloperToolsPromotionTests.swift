import Foundation
import Testing
@testable import Tebo

// The promoted Developer Tools families must produce selectable, recommended
// rows on a real cache shape, and must keep keeping the items when negative
// evidence appears. Each promoted family is exercised through its real table
// row, never a synthetic stand-in.

@Suite("Developer tools promotions")
struct DeveloperToolsPromotionTests {

    private let idleLsof: CleanupActivityGuard.Probe = { _, _, _ in
        BoundedProcessRunner.Result(terminationStatus: 1, stdout: "", stderr: "")
    }

    private func fixtureHome() throws -> URL {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-dev-promo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ root: URL, _ relative: String, _ contents: String = "generated cache") throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func idleScanner(home: URL) -> TargetScanner {
        TargetScanner(home: home.path, runningProcessNames: [], runningProcessPaths: [],
            simulatorActivityProbe: { .idle }, activityProbe: idleLsof)
    }

    @Test("Promoted families produce recommended rows on a real cache shape")
    func promotedFamiliesProduceRows() async throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try write(home, "Library/Developer/Xcode/DerivedData/Proj-a/Build/Products/Debug/Foo.app/embedded.mobileprovision")
        try write(home, "Library/Developer/Xcode/DerivedData/Proj-a/SourcePackages/checkouts/dep/.git/config")
        let latest = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Proj-a/Build/Products/latest")
        try FileManager.default.createSymbolicLink(atPath: latest.path, withDestinationPath: "Debug")
        try write(home, "Library/Developer/Xcode/Products/Debug/old.bin")
        try write(home, ".npm/_cacache/content-v2/x.bin")
        try write(home, ".cache/uv/wheels/y.bin")
        try write(home, "Library/Caches/Homebrew/downloads/pkg.tar.gz")
        try write(home, ".docker/buildx/cache/blob")
        try write(home, "Library/Caches/Google/AndroidStudio2024.1/caches/z.bin")
        try write(home, ".gem/ruby/3.3.0/cache/foo.gem")

        // Three DeviceSupport versions with staggered ages: keep-2 must list
        // only the oldest, and the inner symbol caches stay separately cleanable.
        let deviceSupport = home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")
        let versions: [(String, TimeInterval)] = [
            ("16.0 (20A)", 1_700_000_000), ("16.4 (20E)", 1_710_000_000), ("17.0 (21A)", 1_720_000_000)
        ]
        for (version, epoch) in versions {
            let dir = deviceSupport.appendingPathComponent(version)
            try write(home, "Library/Developer/Xcode/iOS DeviceSupport/\(version)/Symbols/System/Library/Caches/x.bin")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: epoch)], ofItemAtPath: dir.path)
        }

        let outcome = await idleScanner(home: home).scan(targets: DeveloperTools.all, whitelist: [])
        for expected in ["DerivedData/Proj-a", "Xcode/Products/Debug", "_cacache/content-v2", ".cache/uv/wheels",
                         "Homebrew/downloads/pkg.tar.gz", "buildx/cache/blob",
                         "AndroidStudio2024.1/caches", "ruby/3.3.0/cache/foo.gem",
                         "iOS DeviceSupport/16.0 (20A)"] {
            #expect(outcome.deletable.contains { $0.path.hasSuffix(expected) },
                "missing row for \(expected); got \(outcome.deletable.map { URL(fileURLWithPath: $0.path).lastPathComponent })")
        }
        for kept in ["16.4 (20E)", "17.0 (21A)"] {
            #expect(!outcome.deletable.contains { $0.path.hasSuffix(kept) }, "keep-2 must retain \(kept)")
        }
        #expect(outcome.deletable.allSatisfy { $0.recommendedForSelection })
    }

    @Test("Xcode-family rows defer to running or unknown tooling; package caches stay rowed")
    func processBlockedAndUnknownInventories() async throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, "Library/Developer/Xcode/DerivedData/Proj-a/Build/x.bin")
        try write(home, ".npm/_cacache/content-v2/x.bin")

        let running = await TargetScanner(home: home.path,
            processInventory: MoleProcessInventory(names: ["xcodebuild"], executablePaths: []),
            simulatorActivityProbe: { .idle }, activityProbe: idleLsof
        ).scan(targets: DeveloperTools.all, whitelist: [])
        #expect(!running.deletable.contains { $0.path.contains("DerivedData") })
        #expect(running.advisories.contains { $0.detail.contains("Xcode is running") })
        #expect(running.deletable.contains { $0.path.contains("_cacache") })

        let unknown = await TargetScanner(home: home.path,
            processInventory: MoleProcessInventory(names: nil, executablePaths: nil),
            simulatorActivityProbe: { .idle }, activityProbe: idleLsof
        ).scan(targets: DeveloperTools.all, whitelist: [])
        #expect(!unknown.deletable.contains { $0.path.contains("DerivedData") })
        #expect(unknown.advisories.contains { $0.detail.contains("process state is unknown") })
        #expect(unknown.deletable.contains { $0.path.contains("_cacache") })
    }

    @Test("Escaping links, foreign repositories and key material keep the item at scan and removal")
    func policyNegatives() async throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".cache/uv/wheels/y.bin")
        try write(home, ".cache/uv/git/.git/config")
        try write(home, ".cache/uv/key.pem", "PRIVATE KEY")
        let escape = home.appendingPathComponent(".cache/uv/archive/escape")
        try FileManager.default.createDirectory(at: escape.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: escape.path,
            withDestinationPath: home.appendingPathComponent("outside.bin").path)

        let outcome = await idleScanner(home: home).scan(targets: DeveloperTools.all, whitelist: [])
        #expect(outcome.deletable.contains { $0.path.hasSuffix(".cache/uv/wheels") })
        #expect(!outcome.deletable.contains {
            $0.path.contains(".cache/uv/archive") || $0.path.contains(".cache/uv/git")
                || $0.path.hasSuffix(".cache/uv/key.pem")
        })
        #expect(outcome.advisories.contains { $0.detail.contains("symbolic link") })
        #expect(outcome.advisories.contains { $0.detail.contains("repository metadata") })
        #expect(outcome.advisories.contains { $0.detail.contains("credential material") })

        // Removal revalidates with the same policy: the escaping link keeps the item.
        let uv = try #require(DeveloperTools.all.first { $0.label == "uv cache" })
        let reason = await idleScanner(home: home).removalProtectionReason(
            for: home.appendingPathComponent(".cache/uv/archive").path,
            ruleID: uv.ruleID, whitelist: [], targets: [uv])
        #expect(reason?.contains("symbolic link") == true)
    }

    @Test("No promoted row points into a location the safety gate refuses")
    func promotedRowsPassTheGate() {
        // DeviceSupport payloads live under Symbols/System/Library inside every
        // version and their inner caches are named Library/Caches: a row whose
        // own expansion the gate refuses would be a permanent advisory.
        let home = "/Users/test"
        for row in DeveloperTools.all where row.eligibility == .rebuildableCache {
            let resolved = MolePathResolver.resolve(row.path, home: home)
            #expect(SafetyGate.isAllowedToTraverse(path: resolved, whitelist: []),
                "\(row.label) root must be traversable")
            switch row.kind {
            case .directory, .file:
                #expect(SafetyGate.isAllowed(path: resolved, whitelist: []),
                    "\(row.label) target must be removable")
            default:
                let child = resolved.replacingOccurrences(of: "*", with: "synthetic") + "/probe.bin"
                #expect(SafetyGate.isAllowed(path: child, whitelist: []),
                    "\(row.label) listed children must be removable")
            }
        }
    }
}

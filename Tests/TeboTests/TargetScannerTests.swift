import Foundation
import Testing
@testable import Tebo

// MARK: - TargetScanner tests
// The scanner decides what a user is ALLOWED to delete. Its safety rules get their own tests:
// root-requiring rows, report-only rows and rows whose app is running must never come back as
// deletion candidates, no matter how they are written in the table.

@Suite("TargetScanner")
struct TargetScannerTests {

    private final class ListedDirectories: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func read(_ path: String) -> [String] {
            lock.withLock { paths.append(path) }
            return (try? FileManager.default.contentsOfDirectory(atPath: path))?.map {
                (path as NSString).appendingPathComponent($0)
            } ?? []
        }
        var snapshot: [String] { lock.withLock { paths } }
    }

    @Test("Profile globs do not enter Apple-owned, whitelisted or running-app containers")
    func protectedGlobTraversal() async throws {
        let home = try makeHome(files: [
            "Library/Containers/com.apple.Protected/Data/Library/Caches/data.bin": "apple",
            "Library/Containers/org.fixture.Whitelisted/Data/Library/Caches/data.bin": "private",
            "Library/Containers/org.fixture.Running/Data/Library/Caches/data.bin": "active",
            "Library/Containers/org.fixture.Idle/Data/Library/Caches/data.bin": "idle"
        ])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let listing = ListedDirectories()
        let scanner = TargetScanner(home: home, runningProcessNames: ["fixture"], directoryListing: { listing.read($0) })
        let outcome = await scanner.scan(targets: [
            target(path: .homeRelative("Library/Containers/*/Data/Library/Caches/*"), kind: .glob),
            target(path: .homeRelative("Library/Containers/org.fixture.Running/Data/Library/Caches"), kind: .directory,
                   guardSpec: .exact("Fixture"))
        ], whitelist: ["\(home)/Library/Containers/org.fixture.Whitelisted"])
        #expect(outcome.deletable.count == 1)
        #expect(outcome.deletable.first?.path.contains("org.fixture.Idle") == true)
        #expect(!listing.snapshot.contains { $0.contains("com.apple.Protected") || $0.contains("org.fixture.Whitelisted") || $0.contains("org.fixture.Running") })
        #expect(listing.snapshot.contains { $0.contains("org.fixture.Idle/Data/Library/Caches") })
    }

    /// Temporary fake home with the given relative files. Returns its path.
    private func makeHome(files: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root.path
    }

    private func target(
        label: String = "row",
        path: MolePath,
        kind: MoleTargetKind,
        risk: MoleRisk = .safe,
        needsAdmin: Bool = false,
        reportOnly: Bool = false,
        guardSpec: MoleProcessGuard? = nil,
        pruneRule: MolePruneRule? = nil
    ) -> CleanTarget {
        CleanTarget(
            label: label, group: .userEssentials, path: path, kind: kind, risk: risk,
            eligibility: risk == .safe ? .rebuildableCache : .manualReview,
            needsAdmin: needsAdmin, explanation: "test row", processGuard: guardSpec,
            pruneRule: pruneRule, reportOnly: reportOnly, source: "test"
        )
    }

    @Test("Sweep lists real children with measured sizes")
    func sweepFindsChildren() async throws {
        let home = try makeHome(files: [
            "Library/Caches/a.bin": String(repeating: "x", count: 2048),
            "Library/Caches/b.bin": String(repeating: "y", count: 512),
        ])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let outcome = await TargetScanner(home: home, runningProcessNames: []).scan(
            targets: [target(path: .homeRelative("Library/Caches"), kind: .directorySweep)],
            whitelist: []
        )

        #expect(outcome.deletable.count == 2)
        #expect(outcome.deletable.allSatisfy { $0.sizeBytes > 0 })
        #expect(outcome.deletable.map(\.path).allSatisfy { $0.contains("\(home)/Library/Caches/") })
    }

    @Test("Incomplete Clean measurements remain read-only")
    func boundedCleanMeasurement() async throws {
        let home = try makeHome(files: [
            "Library/Caches/fixture/one.bin": "12345",
            "Library/Caches/fixture/two.bin": "67890"
        ])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let outcome = await TargetScanner(home: home, runningProcessNames: [], measurementEntryLimit: 1).scan(
            targets: [target(path: .homeRelative("Library/Caches/fixture"), kind: .directory)], whitelist: [])
        #expect(outcome.deletable.isEmpty)
        #expect(outcome.advisories.contains { $0.group == "Incomplete measurements" })
    }

    @Test("Admin rows are advisory only")
    func adminRowsAreAdvisory() async throws {
        let home = try makeHome(files: ["Library/Caches/x.bin": "data"])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let outcome = await TargetScanner(home: home, runningProcessNames: []).scan(
            targets: [target(path: .homeRelative("Library/Caches"), kind: .directorySweep, needsAdmin: true)],
            whitelist: []
        )

        #expect(outcome.deletable.isEmpty)
        #expect(outcome.advisories.count == 1)
        #expect(outcome.advisories[0].detail.contains("administrator"))
    }

    @Test("Report-only rows are advisory only, and still measured")
    func reportOnlyRowsAreAdvisory() async throws {
        let home = try makeHome(files: ["Library/Trashish/x.bin": String(repeating: "z", count: 4096)])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let outcome = await TargetScanner(home: home, runningProcessNames: []).scan(
            targets: [target(path: .homeRelative("Library/Trashish"), kind: .directory, reportOnly: true)],
            whitelist: []
        )

        #expect(outcome.deletable.isEmpty)
        #expect(outcome.advisories.count == 1)
        #expect(outcome.advisories[0].detail.contains("4 KB"))
    }

    @Test("A running guarded app defers its rows")
    func runningAppDefers() async throws {
        let home = try makeHome(files: ["Library/Caches/SafariCache/x.bin": "data"])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let guarded = target(
            path: .homeRelative("Library/Caches/SafariCache"),
            kind: .directorySweep,
            guardSpec: MoleProcessGuard.exact("Safari")
        )
        let scanner = TargetScanner(home: home, runningProcessNames: ["safari"])

        let blocked = await scanner.scan(targets: [guarded], whitelist: [])
        #expect(blocked.deletable.isEmpty)
        #expect(blocked.advisories.count == 1)
        #expect(blocked.advisories[0].detail.contains("Safari is running"))

        // Same row, app not running: now it is a normal candidate.
        let clear = await TargetScanner(home: home, runningProcessNames: [])
            .scan(targets: [guarded], whitelist: [])
        #expect(clear.deletable.count == 1, "paths: \(clear.deletable.map(\.path))")
    }

    @Test("A general cache sweep cannot bypass a running app's guarded target")
    func generalSweepHonorsRunningGuard() async throws {
        let home = try makeHome(files: [
            "Library/Caches/FixtureEditor/cache.bin": "active",
            "Library/Caches/OtherEditor/cache.bin": "idle"
        ])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let targets = [
            target(label: "general", path: .homeRelative("Library/Caches"), kind: .directorySweep),
            target(label: "guarded", path: .homeRelative("Library/Caches/FixtureEditor"), kind: .directorySweep,
                   guardSpec: .exact("FixtureEditor"))
        ]
        let outcome = await TargetScanner(home: home, runningProcessNames: ["fixtureeditor"]).scan(targets: targets, whitelist: [])
        #expect(!outcome.deletable.contains { $0.path.contains("FixtureEditor") },
                "home: \(home), rows: \(outcome.deletable.map(\.path)), advisories: \(outcome.advisories.map(\.detail))")
        #expect(outcome.deletable.contains { $0.path.contains("OtherEditor") })
    }

    @Test("An app launched after preview keeps its cache at the Trash boundary")
    func appStartsAfterPreview() async throws {
        let home = try makeHome(files: ["Library/Caches/FixtureEditor/cache.bin": "active"])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let targets = [target(path: .homeRelative("Library/Caches/FixtureEditor"), kind: .directory,
                              guardSpec: .exact("FixtureEditor"))]
        let clear = await TargetScanner(home: home, runningProcessNames: []).scan(targets: targets, whitelist: [])
        let row = try #require(clear.deletable.first)
        let identity = try #require(FileIdentity.read(path: row.path))
        let active = TargetScanner(home: home, runningProcessNames: ["fixtureeditor"])
        let report = await DeletePipeline().trash(paths: [row.path], whitelist: [],
            expectedIdentities: [row.path: identity], additionalValidation: {
                active.runningProtectionReason(for: $0, targets: targets)
            })
        #expect(report.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: row.path))
        #expect(report.outcomes.contains {
            if case .failed(let reason) = $0.result { return reason.contains("FixtureEditor is running") }
            return false
        })
        #expect(active.runningProtectionReason(for: "\(home)/Library/Caches/OtherEditor", targets: targets) == nil)
    }

    @Test("Apple-owned data is dropped even when a row points at it")
    func appleDataNeverDeletable() async throws {
        // SafetyGate refuses com.apple. fragments, so a table row aimed at Apple-owned data must
        // come back empty rather than as a selectable row.
        let home = try makeHome(files: ["Library/Caches/com.apple.SomeDaemon/x.bin": "data"])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let outcome = await TargetScanner(home: home, runningProcessNames: []).scan(
            targets: [target(path: .homeRelative("Library/Caches"), kind: .directorySweep)],
            whitelist: []
        )

        #expect(outcome.deletable.isEmpty)
    }

    @Test("Glob rows match only their pattern")
    func globMatchesPattern() async throws {
        let home = try makeHome(files: [
            "Library/Caches/com.example.one/cache.bin": "aaaa",
            "Library/Caches/com.example.two/cache.bin": "bbbb",
            "Library/Caches/com.other.three/cache.bin": "cccc",
        ])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let outcome = await TargetScanner(home: home, runningProcessNames: []).scan(
            targets: [target(
                path: .homeRelative("Library/Caches/com.example.*"),
                kind: .glob
            )],
            whitelist: []
        )

        #expect(outcome.deletable.count == 2)
        #expect(outcome.deletable.allSatisfy { $0.path.contains("com.example.") })
        #expect(!outcome.deletable.contains { $0.path.contains("com.other.three") })
    }

    @Test("Framework pruning keeps the version the app is using")
    func frameworkPruneKeepsCurrent() async throws {
        let home = try makeHome(files: [
            "Chrome.app/Contents/Frameworks/Chrome Framework.framework/Versions/120/lib": "old",
            "Chrome.app/Contents/Frameworks/Chrome Framework.framework/Versions/121/lib": "new",
        ])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let versions = "\(home)/Chrome.app/Contents/Frameworks/Chrome Framework.framework/Versions"
        // Dictionary iteration does not establish chronological version order.
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-20 * 86_400)],
            ofItemAtPath: "\(versions)/120")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-10 * 86_400)],
            ofItemAtPath: "\(versions)/121")
        try FileManager.default.createSymbolicLink(
            atPath: "\(versions)/Current", withDestinationPath: "121"
        )

        let outcome = await TargetScanner(home: home, runningProcessNames: []).scan(
            targets: [target(
                path: .absolute("\(home)/Chrome.app"),
                kind: .frameworkVersions(framework: "Chrome Framework.framework"),
                pruneRule: .keepCurrentSymlinkTarget
            )],
            whitelist: []
        )

        #expect(outcome.deletable.count == 1)
        #expect(try #require(outcome.deletable.first).path.hasSuffix("/Versions/120"))
    }

    @Test("Profile globs expand wildcard parent directories without following symlinks")
    func nestedProfileGlobs() async throws {
        let home = try makeHome(files: [
            "Library/Application Support/Chrome/Default/Code Cache/one.bin": "one",
            "Library/Application Support/Chrome/Profile 2/Code Cache/two.bin": "two",
            "outside/Code Cache/kept.bin": "kept"
        ])
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createSymbolicLink(
            atPath: "\(home)/Library/Application Support/Chrome/Linked Profile",
            withDestinationPath: "\(home)/outside")
        let outcome = await TargetScanner(home: home, runningProcessNames: []).scan(targets: [
            target(path: .homeRelative("Library/Application Support/Chrome/*/Code Cache/*"), kind: .glob)
        ], whitelist: [])
        #expect(Set(outcome.deletable.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["one.bin", "two.bin"])
        #expect(outcome.deletable.reduce(0) { $0 + $1.sizeBytes } == 6)
        #expect(!outcome.truncated)
    }

    @Test("Missing locations are counted, never invented")
    func absentLocationsCounted() async throws {
        let home = try makeHome(files: ["Library/Caches/real.bin": "data"])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let outcome = await TargetScanner(home: home, runningProcessNames: []).scan(
            targets: [
                target(label: "exists", path: .homeRelative("Library/Caches/real.bin"), kind: .file),
                target(label: "gone", path: .homeRelative("Library/Caches/does-not-exist"), kind: .directorySweep),
            ],
            whitelist: []
        )

        #expect(outcome.deletable.count == 1)
        #expect(outcome.absentLocationCount == 1)
    }

    @Test("Whitelisted paths are dropped before the UI sees them")
    func whitelistRespected() async throws {
        let home = try makeHome(files: [
            "Library/Caches/keep-me/x.bin": "data",
            "Library/Caches/clean-me/y.bin": "data",
        ])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let outcome = await TargetScanner(home: home, runningProcessNames: []).scan(
            targets: [target(path: .homeRelative("Library/Caches"), kind: .directorySweep)],
            whitelist: ["keep-me"]
        )

        #expect(outcome.deletable.count == 1)
        #expect(try #require(outcome.deletable.first).path.hasSuffix("clean-me"))
    }

    @Test("Whole-volume report rows are listed without being walked for a size")
    func wholeVolumeReportRowSkipsSizing() async throws {
        // /Volumes exists on every Mac and can hold a mounted share or disk image, so walking it
        // just to print a number for a row we will not delete can take minutes. The row still
        // appears, with its location, and without a size.
        let outcome = await TargetScanner(home: NSHomeDirectory(), runningProcessNames: []).scan(
            targets: [
                target(label: "volumes", path: .absolute("/Volumes"), kind: .directory, reportOnly: true),
            ],
            whitelist: []
        )

        #expect(outcome.advisories.count == 1)
        let detail = try #require(outcome.advisories.first?.detail)
        #expect(detail.contains("/Volumes"), "the advisory must still say where the row points")
        #expect(!detail.contains("("), "a whole-volume row must not carry a measured size")
    }
}

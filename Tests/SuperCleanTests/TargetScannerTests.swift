import Foundation
import Testing
@testable import SuperClean

// MARK: - TargetScanner tests
// The scanner decides what a user is ALLOWED to delete. Its safety rules get their own tests:
// root-requiring rows, report-only rows and rows whose app is running must never come back as
// deletion candidates, no matter how they are written in the table.

@Suite("TargetScanner")
struct TargetScannerTests {

    /// Temporary fake home with the given relative files. Returns its path.
    private func makeHome(files: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superclean-home-\(UUID().uuidString)")
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
        #expect(outcome.deletable[0].path.hasSuffix("/Versions/120"))
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
        #expect(outcome.deletable[0].path.hasSuffix("clean-me"))
    }
}

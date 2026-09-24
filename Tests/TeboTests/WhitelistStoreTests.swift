import Foundation
import Testing
@testable import Tebo

// MARK: - WhitelistStore tests
// Round-trip + comment handling, all in a temp dir (never touches ~/).

/// Unique scratch file per test run.
private func scratchWhitelistURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("tebo-test-\(UUID().uuidString)/whitelist")
}

@Suite("WhitelistStore")
struct WhitelistStoreTests {

    @Test("Round-trips entries through disk")
    func roundTrip() {
        let url = scratchWhitelistURL()
        WhitelistStore.save(["b-entry", "a-entry"], to: url)
        #expect(WhitelistStore.load(from: url) == ["a-entry", "b-entry"])
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("Skips blanks and # comments, trims whitespace")
    func skipsComments() {
        let url = scratchWhitelistURL()
        let text = "# header\n\n  com.myapp  \n# another\ncom.other\n"
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
        #expect(WhitelistStore.load(from: url) == ["com.myapp", "com.other"])
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("Missing file loads as empty")
    func missingFile() {
        #expect(WhitelistStore.load(from: scratchWhitelistURL()).isEmpty)
    }
}

// MARK: - CleanerService sizing tests
// Verifies recursive measurement on a controlled temp tree.

@Suite("CleanerService sizing")
struct CleanerServiceSizingTests {

    /// Builds: root/keep.txt (10 B) + root/sub/nested.bin (100 B).
    private func makeTree() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-size-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try? Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("keep.txt"))
        try? Data(repeating: 0, count: 100).write(to: sub.appendingPathComponent("nested.bin"))
        return root
    }

    @Test("Measures nested files recursively")
    func recursiveSize() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CleanerService().recursiveSize(at: root.path) == 110)
    }

    @Test("Missing path measures zero")
    func missingPath() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-nope-\(UUID().uuidString)").path
        #expect(CleanerService().recursiveSize(at: missing) == 0)
    }
}

// MARK: - CleanerService location scan tests
// Guards the Trash-safety rule: no row may point at the scanned dir itself.

@Suite("CleanerService location scan")
struct CleanerServiceLocationTests {

    /// Builds: root/app-cache/data.bin (50 B) + root/loose.log (20 B).
    private func makeLocation() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-loc-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("app-cache")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try? Data(repeating: 0, count: 50).write(to: sub.appendingPathComponent("data.bin"))
        try? Data(repeating: 0, count: 20).write(to: root.appendingPathComponent("loose.log"))
        return root
    }

    @Test("Lists children individually, never the location dir")
    func noParentRow() async {
        let root = makeLocation()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = await CleanerService().scanLocation(
            at: root.path, label: "Test", reason: "test", whitelist: []
        )
        // Suffix matching: enumeration reports symlink-resolved paths
        // (/private/var/...) while the input keeps /var/... — compare tails.
        #expect(rows.count == 2)
        #expect(!rows.contains { $0.path == root.path })
        #expect(!rows.contains { $0.path == root.path + "/" })
        let byTail = Dictionary(uniqueKeysWithValues: rows.map {
            (URL(fileURLWithPath: $0.path).lastPathComponent, $0.sizeBytes)
        })
        #expect(byTail["app-cache"] == 50)
        #expect(byTail["loose.log"] == 20)
    }

    @Test("Respects whitelist inside the location")
    func whitelistInside() async {
        let root = makeLocation()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = await CleanerService().scanLocation(
            at: root.path, label: "Test", reason: "test",
            whitelist: ["app-cache"]
        )
        #expect(rows.count == 1)
        #expect(rows.first?.path.hasSuffix("loose.log") == true)
    }
}

// MARK: - CleanerService purge traversal tests
// Dot-containers skipped, found artifacts not descended into.

@Suite("CleanerService purge traversal")
struct CleanerServicePurgeTests {

    /// Builds: proj/node_modules/pkg (10 B) + proj/.hidden-cache/x (99 B).
    private func makeProject() -> URL {
        let proj = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-proj-\(UUID().uuidString)")
        let nm = proj.appendingPathComponent("node_modules/pkg")
        let hidden = proj.appendingPathComponent(".hidden-cache")
        try? FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try? Data(repeating: 0, count: 10).write(to: nm.appendingPathComponent("index.js"))
        try? Data(repeating: 0, count: 99).write(to: hidden.appendingPathComponent("x"))
        return proj
    }

    @Test("Finds artifacts, skips dot containers")
    func dotSkip() {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        let rows = CleanerService().findArtifacts(
            under: proj.path, depth: 0, maxDepth: 4, whitelist: []
        )
        #expect(rows.count == 1)
        #expect(rows.first?.path.hasSuffix("node_modules") == true)
        #expect(rows.first?.sizeBytes == 10)
    }
}

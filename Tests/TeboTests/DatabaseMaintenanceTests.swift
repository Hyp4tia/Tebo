import Foundation
import SQLite3
import Testing
@testable import Tebo

@Suite("Database maintenance")
struct DatabaseMaintenanceTests {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-db-\(UUID())")
        let path = root.appendingPathComponent("Library/Messages/chat.db")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (root, path)
    }
    private func open(_ path: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        #expect(sqlite3_open(path.path, &handle) == SQLITE_OK)
        return try #require(handle)
    }
    private func queryCount(_ path: URL) throws -> Int {
        let handle = try open(path); defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM messages", -1, &statement, nil) == SQLITE_OK)
        let prepared = try #require(statement); defer { sqlite3_finalize(prepared) }
        #expect(sqlite3_step(prepared) == SQLITE_ROW)
        return Int(sqlite3_column_int(prepared, 0))
    }

    @Test("Preview and active-app guards do not modify databases or create backups")
    func previewAndRunningGuard() async throws {
        let (root, path) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try open(path)
        #expect(sqlite3_exec(handle, "CREATE TABLE messages(id INTEGER); INSERT INTO messages VALUES(1);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let before = try Data(contentsOf: path)
        let service = DatabaseMaintenance(home: root.path)
        let candidate = try #require(service.candidates().first)
        #expect(await service.optimize(candidate, preview: true, whitelist: [], runningIDs: []) == .preview)
        let guarded = await service.optimize(candidate, preview: false, whitelist: [], runningIDs: [candidate.ownerBundleID])
        #expect(guarded == .skipped("Quit the owning app first"))
        #expect(try Data(contentsOf: path) == before)
        #expect(!FileManager.default.fileExists(atPath: service.backupDirectory.path))
    }

    @Test("Optimization backs up committed WAL data and preserves records")
    func walBackupAndVacuum() async throws {
        let (root, path) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try open(path); defer { sqlite3_close(source) }
        let sql = "PRAGMA journal_mode=WAL; CREATE TABLE messages(id INTEGER PRIMARY KEY, body BLOB); "
            + "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<250) "
            + "INSERT INTO messages SELECT x, randomblob(4096) FROM n; DELETE FROM messages WHERE id>5;"
        #expect(sqlite3_exec(source, sql, nil, nil, nil) == SQLITE_OK)
        let service = DatabaseMaintenance(home: root.path)
        let candidate = try #require(service.candidates().first)
        let result = await service.optimize(candidate, preview: false, whitelist: [], runningIDs: [])
        guard case .optimized(let backup) = result else { Issue.record("Expected optimization, got \(result)"); return }
        #expect(try queryCount(path) == 5)
        #expect(try queryCount(URL(fileURLWithPath: backup)) == 5)
        #expect(backup.hasPrefix(service.backupDirectory.path + "/"))
    }

    @Test("An unrelated database cannot be submitted as a maintenance target")
    func targetAllowlist() async throws {
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("unrelated.sqlite")
        let handle = try open(unrelated); sqlite3_close(handle)
        let identity = try #require(FileIdentity.read(path: unrelated.path))
        let candidate = MaintenanceDatabase(name: "Unrelated", path: unrelated.path, ownerBundleID: "org.fake", identity: identity)
        let result = await DatabaseMaintenance(home: root.path).optimize(candidate, preview: false, whitelist: [], runningIDs: [])
        #expect(result == .skipped("Database changed since review"))
    }
}

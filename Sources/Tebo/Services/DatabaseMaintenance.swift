import Foundation
import SQLite3

struct MaintenanceDatabase: Sendable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let ownerBundleID: String
    let identity: FileIdentity
}

enum DatabaseMaintenanceResult: Sendable, Equatable {
    case preview
    case unchanged
    case optimized(backupPath: String)
    case skipped(String)
    case failed(String)
}

struct DatabaseMaintenance: Sendable {
    let home: String
    init(home: String = NSHomeDirectory()) { self.home = home }
    var backupDirectory: URL { URL(fileURLWithPath: "\(home)/Library/Application Support/Tebo/MaintenanceBackups") }

    func candidates() -> [MaintenanceDatabase] {
        var paths = [("Safari history", "Library/Safari/History.db", "com.apple.Safari"),
                     ("Safari sites", "Library/Safari/TopSites.db", "com.apple.Safari"),
                     ("Messages", "Library/Messages/chat.db", "com.apple.MobileSMS")]
        let mail = URL(fileURLWithPath: "\(home)/Library/Mail")
        for version in (try? FileManager.default.contentsOfDirectory(at: mail, includingPropertiesForKeys: nil)) ?? [] where version.lastPathComponent.hasPrefix("V") {
            paths.append(("Mail index", "Library/Mail/\(version.lastPathComponent)/MailData/Envelope Index", "com.apple.mail"))
        }
        return paths.compactMap { name, relative, owner in
            let url = URL(fileURLWithPath: "\(home)/\(relative)")
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let identity = FileIdentity.read(path: url.path) else { return nil }
            return MaintenanceDatabase(name: name, path: url.path, ownerBundleID: owner, identity: identity)
        }
    }

    func optimize(_ candidate: MaintenanceDatabase, preview: Bool, whitelist: Set<String>, runningIDs: Set<String>) async -> DatabaseMaintenanceResult {
        guard candidates().contains(where: { $0.path == candidate.path && $0.identity == candidate.identity }) else {
            return .skipped("Database changed since review")
        }
        guard !runningIDs.contains(candidate.ownerBundleID) else { return .skipped("Quit the owning app first") }
        if let reason = PathValidator.validate(path: candidate.path, whitelist: whitelist) { return .skipped(reason.rawValue) }
        guard !preview else { return .preview }
        let worker = Task.detached(priority: .utility) { perform(candidate) }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        await OperationLog.shared.record("Optimize database \(candidate.name): \(result)")
        return result
    }

    private func perform(_ candidate: MaintenanceDatabase) -> DatabaseMaintenanceResult {
        var database: OpaquePointer?
        guard sqlite3_open_v2(candidate.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return .failed("Database is unavailable or access was denied")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        let deadline = SQLiteDeadline(Date.now.addingTimeInterval(60))
        let retained = Unmanaged.passRetained(deadline)
        defer { retained.release() }
        sqlite3_progress_handler(database, 1000, { raw in
            guard let raw else { return 1 }
            return Date.now >= Unmanaged<SQLiteDeadline>.fromOpaque(raw).takeUnretainedValue().date || Task.isCancelled ? 1 : 0
        }, retained.toOpaque())
        guard scalar(database, "PRAGMA quick_check") == "ok" else { return .skipped("Integrity check failed; database kept") }
        guard let free = scalar(database, "PRAGMA freelist_count").flatMap(Int.init) else { return .failed("Could not inspect free pages") }
        guard free > 0 else { return .unchanged }
        guard PathValidator.validate(path: backupDirectory.path, whitelist: []) == nil else {
            return .failed("Backup directory is not safe")
        }
        do {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return .failed("Could not create a private backup directory") }
        guard PathValidator.validate(path: backupDirectory.path, whitelist: []) == nil,
              (try? backupDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return .failed("Backup directory is not safe")
        }
        let backupURL = backupDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        var destination: OpaquePointer?
        guard sqlite3_open_v2(backupURL.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let destination else {
            if let destination { sqlite3_close(destination) }
            return .failed("Could not open the backup")
        }
        defer { sqlite3_close(destination) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        guard let copy = sqlite3_backup_init(destination, "main", database, "main") else { return .failed("Could not begin database backup") }
        var status = SQLITE_OK
        let backupDeadline = Date.now.addingTimeInterval(15)
        repeat {
            status = sqlite3_backup_step(copy, 256)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.01) }
        } while [SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED].contains(status) && Date.now < backupDeadline && !Task.isCancelled
        let finished = sqlite3_backup_finish(copy)
        guard status == SQLITE_DONE, finished == SQLITE_OK else { return .failed("Backup did not complete; source database was not changed") }
        guard !Task.isCancelled, FileIdentity.read(path: candidate.path) == candidate.identity else {
            return .skipped("Database changed or action cancelled; source was not optimized")
        }
        guard sqlite3_exec(database, "VACUUM", nil, nil, nil) == SQLITE_OK else {
            return .failed("Optimization failed: \(String(cString: sqlite3_errmsg(database))). Backup: \(backupURL.path)")
        }
        return .optimized(backupPath: backupURL.path)
    }

    private func scalar(_ database: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}

private final class SQLiteDeadline: @unchecked Sendable {
    let date: Date
    init(_ date: Date) { self.date = date }
}

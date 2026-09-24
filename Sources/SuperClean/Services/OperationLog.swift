import Foundation
import OSLog

// MARK: - OperationLog
// Append-only log of everything we preview/delete.
// Powers the Toolbox > History tab (like `mo history`).
// Path: ~/Library/Logs/superclean/operations.log

/// Tiny file logger. Actor = thread-safe, no locks needed.
/// Usage: `await OperationLog.shared.record("Previewed 12 items (4.5 GB)")`
public actor OperationLog {

    /// Shared instance used by all tabs.
    public static let shared = OperationLog()

    private let logger = Logger(subsystem: "com.superclean.app", category: "operations")
    private let fileURL: URL

    /// Log location. Static so Settings and the self-test can show it without touching the actor.
    public static func fileURL() -> URL {
        logDirectory().appendingPathComponent("operations.log")
    }

    private static func logDirectory() -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/superclean", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    init() {
        self.fileURL = Self.fileURL()
        try? FileManager.default.createDirectory(
            at: Self.logDirectory(), withIntermediateDirectories: true
        )
    }

    /// Append one line with timestamp. Never throws — logging must not crash scans.
    public func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        logger.info("\(message, privacy: .public)")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Append efficiently without loading the whole file.
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Read last N lines for the History view. Cheap tail-read.
    public func recentLines(limit: Int = 100) -> [String] {
        guard let text = try? String(contentsOf: fileURL) else { return [] }
        let lines = text.split(separator: "\n").map(String.init)
        return Array(lines.suffix(limit))
    }
}

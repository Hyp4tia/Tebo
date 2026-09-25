import Foundation

// MARK: - WhitelistStore
// Persists the user's protected paths to ~/.config/tebo/whitelist
// (one substring per line, like Mole). Pure logic, easy to unit-test:
// pass an explicit URL in tests, use the default live path in the app.

/// Loads/saves the whitelist file. All methods are static + Sendable.
public enum WhitelistStore {

    /// Live config dir: ~/.config/tebo (created on first save).
    public static func configDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tebo", isDirectory: true)
    }

    /// Live whitelist file URL.
    public static func fileURL() -> URL {
        configDirectory().appendingPathComponent("whitelist")
    }

    /// Load entries, ignoring blanks and `#` comments.
    /// Missing file = empty set (not an error).
    public static func load(from url: URL? = nil) -> Set<String> {
        let file = url ?? fileURL()
        guard let text = try? String(contentsOf: file) else { return [] }
        var out = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            out.insert(line)
        }
        return out
    }

    /// Save entries sorted, with a header comment. Creates the config dir.
    public static func save(_ entries: Set<String>, to url: URL? = nil) {
        let file = url ?? fileURL()
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var text = "# Tebo whitelist: one protected substring per line.\n"
        for entry in entries.sorted() {
            text += "\(entry)\n"
        }
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}

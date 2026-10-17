import Darwin
import Foundation

// MARK: - WhitelistStore
// Persists the user's protected paths to ~/.config/tebo/whitelist
// (one substring per line, like Mole). Pure logic, easy to unit-test:
// pass an explicit URL in tests, use the default live path in the app.

/// Loads/saves the whitelist file. All methods are static + Sendable.
public enum WhitelistStore {

    public struct Snapshot: Sendable {
        public let entries: Set<String>
        public let error: String?
    }

    /// Live config dir: ~/.config/tebo (created on first save).
    public static func configDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tebo", isDirectory: true)
    }

    /// Live whitelist file URL.
    public static func fileURL() -> URL {
        configDirectory().appendingPathComponent("whitelist")
    }

    /// Failed reads protect every path instead of silently discarding exclusions.
    public static func load(from url: URL? = nil) -> Set<String> {
        snapshot(from: url).entries
    }

    public static func snapshot(from url: URL? = nil) -> Snapshot {
        let file = url ?? fileURL()
        let text: String
        do {
            var info = stat()
            guard lstat(file.path, &info) == 0 else {
                if errno == ENOENT, confirmedMissing(file) {
                    return url == nil ? packagedDefaults() : Snapshot(entries: [], error: nil)
                }
                return unavailable()
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1_048_576,
                  let decoded = String(data: try Data(contentsOf: file), encoding: .utf8),
                  !decoded.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value)
                  }) else { return unavailable() }
            text = decoded
        } catch {
            return unavailable()
        }
        var out = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            out.insert(line)
        }
        return Snapshot(entries: out, error: nil)
    }

    /// Save entries sorted, with a header comment. Creates the config dir.
    @discardableResult
    public static func save(_ entries: Set<String>, to url: URL? = nil) -> String? {
        let file = url ?? fileURL()
        guard entries.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("#")
            && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            return "Protection entries must be nonempty single-line substrings."
        }
        var text = "# Tebo whitelist: one protected substring per line.\n"
        for entry in entries.sorted() {
            text += "\(entry)\n"
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Protections could not be saved. The previous policy is still active."
        }
    }

    private static func unavailable() -> Snapshot {
        // An empty set used to authorize cleanup when the file was corrupt or unreadable.
        Snapshot(entries: ["/"], error: "Protection settings could not be read. Cleanup is blocked. Repair ~/.config/tebo/whitelist and reload protections.")
    }

    private static func confirmedMissing(_ file: URL) -> Bool {
        var parent = file.deletingLastPathComponent()
        while true {
            var info = stat()
            if lstat(parent.path, &info) == 0 {
                return info.st_mode & S_IFMT == S_IFDIR && FileManager.default.isReadableFile(atPath: parent.path)
            }
            guard errno == ENOENT, parent.path != "/" else { return false }
            parent.deleteLastPathComponent()
        }
    }

    private static func packagedDefaults() -> Snapshot {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "whitelist", withExtension: "default", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: "whitelist", withExtension: "default")
        #endif
        guard let url else { return unavailable() }
        return snapshot(from: url)
    }
}

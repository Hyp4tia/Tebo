import Foundation

// MARK: - MolePaths
// macOS-specific knowledge copied as DATA from tw93/Mole (GPL-3.0).
// We reimplement the logic in Swift — no Go runtime needed.
// Each entry = a folder Mole considers safe to preview.

/// One known-safe cleanup location.
public struct KnownCleanLocation: Hashable, Sendable {
    public let label: String        // Shown in UI, e.g. "User app cache"
    public let relativePath: String // Relative to home, e.g. "Library/Caches"
    public let explanation: String  // Why it is rebuildable

    public init(label: String, relativePath: String, explanation: String) {
        self.label = label
        self.relativePath = relativePath
        self.explanation = explanation
    }
}

/// Curated safe list. Small on purpose — expand only with measured value.
/// Full Mole tables live in Mole's `lib/clean/*.sh`; port more rows here in M2.
public enum MolePaths {

    /// Safe-by-default locations (mirrors `mo clean` essentials).
    public static let safeCleanLocations: [KnownCleanLocation] = [
        KnownCleanLocation(
            label: "User app cache",
            relativePath: "Library/Caches",
            explanation: "Rebuildable app caches"
        ),
        KnownCleanLocation(
            label: "User app logs",
            relativePath: "Library/Logs",
            explanation: "Rotating logs, safe to prune"
        ),
        KnownCleanLocation(
            label: "Xcode derived data",
            relativePath: "Library/Developer/Xcode/DerivedData",
            explanation: "Rebuilt on next Xcode build"
        ),
        KnownCleanLocation(
            label: "Homebrew cache",
            relativePath: "Library/Caches/Homebrew",
            explanation: "Redownloadable bottles"
        ),
        KnownCleanLocation(
            label: "npm cache",
            relativePath: ".npm",
            explanation: "Reset via npm cache, never delete blindly"
        )
    ]

    /// Installer file extensions (mirrors `mo installer`).
    public static let installerExtensions: Set<String> = [
        "dmg", "pkg", "mpkg", "iso", "xip", "zip"
    ]

    /// Rebuildable project artifact folders (mirrors `mo purge`).
    public static let purgeFolderNames: Set<String> = [
        "node_modules", "target", ".build", "build", "dist", ".next", "vendor"
    ]

    /// Roots searched for project artifacts (only existing ones are scanned).
    /// Mirrors Mole's defaults like ~/Projects, ~/GitHub, ~/dev.
    public static var projectSearchRoots: [String] {
        ["Projects", "GitHub", "dev", "Documents/Projects", "Work", "Code"]
            .map { absolutePath(homeRelative: $0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Folders swept for installer files (mirrors `mo installer` essentials).
    public static var installerSearchDirs: [String] {
        ["Downloads", "Desktop"]
            .map { absolutePath(homeRelative: $0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Expand ~/ to absolute path. Cheap, no disk access.
    public static func absolutePath(homeRelative: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(homeRelative)
    }
}

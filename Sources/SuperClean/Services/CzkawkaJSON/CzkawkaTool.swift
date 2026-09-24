import Foundation

// MARK: - CzkawkaTool
// Single source of truth for the czkawka_cli subcommands SuperClean drives.
// `rawValue` IS the exact clap subcommand name: CzkawkaBridge builds argv from it
// and CzkawkaJSON dispatches parsing on it. Never type the clap names anywhere else.

/// One czkawka_cli tool (subcommand). Raw values are the exact clap names, verified
/// against `Engines/czkawka_cli --help` (czkawka 12.0.2): dup, empty-folders, big,
/// empty-files, temp, image, music, video.
public enum CzkawkaTool: String, CaseIterable, Sendable, Hashable {
    case duplicates = "dup"
    case emptyFolders = "empty-folders"
    case bigFiles = "big"
    case emptyFiles = "empty-files"
    case temporaryFiles = "temp"
    case similarImages = "image"
    case similarMusic = "music"
    case similarVideos = "video"
    case invalidSymlinks = "symlinks"
    case brokenFiles = "broken"
    case wrongExtensions = "ext"
    case badNames = "bad-names"

    /// Exact clap subcommand name, e.g. "empty-folders". Use this to build argv.
    public var clapName: String { rawValue }

    /// Human label used in scan UI / item reasons.
    public var displayName: String {
        switch self {
        case .duplicates: "Duplicates"
        case .emptyFolders: "Empty Folders"
        case .bigFiles: "Large Files"
        case .emptyFiles: "Empty Files"
        case .temporaryFiles: "Temporary Files"
        case .similarImages: "Similar Images"
        case .similarMusic: "Similar Music"
        case .similarVideos: "Similar Videos"
        case .invalidSymlinks: "Invalid Symlinks"
        case .brokenFiles: "Broken Files"
        case .wrongExtensions: "Wrong Extensions"
        case .badNames: "Bad Names"
        }
    }

    /// Extra flags CzkawkaBridge appends after the shared set, per tool.
    /// bad-names checks are opt-in: with none of -u/-j/-w/-n/-a the engine checks
    /// nothing and returns [] (verified against 12.0.2), so the bridge enables all
    /// five checks. Note what is deliberately NOT here: `-F` (fix) exists for
    /// bad-names and ext but rewrites files in place, and `-D`/`-y` would delete.
    /// SuperClean only reports: the app never passes fix or delete flags.
    public var extraClapFlags: [String] {
        switch self {
        case .badNames: ["-u", "-j", "-w", "-n", "-a"]
        default: []
        }
    }
}

// MARK: - CzkawkaDupSearchMethod
// `dup -s <method>` values, exact clap strings (case-insensitive to clap, but we pass
// the canonical uppercase forms shown in `czkawka_cli dup -h`).

/// Duplicate search method. Changes both the engine's grouping AND the JSON shape it
/// writes (see CzkawkaJSON): HASH nests groups per size key, SIZE/NAME are flat per
/// key, SIZE_NAME is a bare array of groups with no keys at all.
public enum CzkawkaDupSearchMethod: String, CaseIterable, Sendable, Hashable {
    case hash = "HASH"
    case size = "SIZE"
    case name = "NAME"
    case sizeName = "SIZE_NAME"

    /// Exact clap value for `-s`, e.g. "SIZE_NAME".
    public var clapValue: String { rawValue }
}

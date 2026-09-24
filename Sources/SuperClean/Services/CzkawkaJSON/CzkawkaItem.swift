import Foundation

// MARK: - CzkawkaItem
// Uniform, UI-ready item model for everything the czkawka engine finds.
// Every tool flattens into this one struct: path + size in bytes are always present,
// tool-specific extras ride in `detail` and `groupID`. This is the model a shared
// ScanTab renders; items are small, Sendable, Hashable and Identifiable so a LazyVStack
// can render thousands without any other machinery.

/// One finding from a czkawka scan.
public struct CzkawkaItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Absolute path the engine reported (file for most tools, folder for empty-folders).
    public let path: String
    /// Size in bytes. 0 for empty folders / empty files.
    public let sizeBytes: Int64
    /// Which tool found it.
    public let tool: CzkawkaTool
    /// Group identity for grouped tools (duplicates, similar media). Items with the same
    /// groupID belong together and should be selected/unselected as a unit.
    public let groupID: String?
    /// Tool-specific extras (hash, dimensions, tags, ...). nil for the flat tools.
    public let detail: CzkawkaItemDetail?

    public init(
        id: UUID = UUID(),
        path: String,
        sizeBytes: Int64,
        tool: CzkawkaTool,
        groupID: String? = nil,
        detail: CzkawkaItemDetail? = nil
    ) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.tool = tool
        self.groupID = groupID
        self.detail = detail
    }

    /// Last path component, for loud row titles.
    public var displayName: String {
        (path as NSString).lastPathComponent
    }

    /// UI category label ("Duplicates", "Empty Folders", ...).
    public var category: String { tool.displayName }

    /// Short human reason, safe to show under the path.
    public var reason: String {
        switch detail {
        case .duplicate: return "Same content as the rest of its group"
        case .similarImage(let width, let height, let difference):
            let pct = Int((1 - Double(min(max(difference, 0), 40)) / 40) * 100)
            return "\(width)x\(height)px, \(pct)% similar to its group"
        case .similarMusic(let title, let artist, _, _):
            let tag = [title, artist].filter { !$0.isEmpty }.joined(separator: " by ")
            return tag.isEmpty ? "Same audio tags as its group" : "\(tag), same tags as its group"
        case .similarVideo(let width, let height, _, _):
            return "\(width)x\(height)px, visually similar to its group"
        case .invalidSymlink(let destination, let error):
            return "Points to \(destination) which does not exist (\(error))"
        case .brokenFile(let errors):
            return "Corrupt content: \(errors.keys.sorted().joined(separator: ", "))"
        case .wrongExtension(let current, let proper):
            return "Actually a .\(proper) file, named .\(current)"
        case .badName(let suggested):
            return "Suggested name: \(suggested)"
        case nil:
            switch tool {
            case .emptyFolders: return "Folder contains no files"
            case .emptyFiles: return "Zero bytes"
            case .bigFiles: return "Among the largest files found"
            case .temporaryFiles: return "Temp/backup extension"
            default: return ""
            }
        }
    }

    /// 1.0 = identical, 0.0 = as different as the engine allows. Similar images only.
    public var similarity: Double? {
        guard case .similarImage(_, _, let difference) = detail else { return nil }
        return 1 - Double(min(max(difference, 0), 40)) / 40
    }

    /// Pixel dimensions for similar images/videos. nil elsewhere.
    public var dimensions: (width: Int, height: Int)? {
        switch detail {
        case .similarImage(let width, let height, _): (width, height)
        case .similarVideo(let width, let height, _, _): (width, height)
        default: nil
        }
    }
}

// MARK: - CzkawkaItemDetail

/// Tool-specific payload. Mirrors exactly what the engine JSON carries per tool
/// (verified against the captured fixtures in Tests/Fixtures/czkawka).
public enum CzkawkaItemDetail: Hashable, Sendable {
    /// Exact duplicate: the group's content hash (64-hex BLAKE3 in HASH mode, "" for
    /// SIZE/NAME/SIZE_NAME modes which never hash).
    case duplicate(hash: String)
    /// Similar image: pixel size plus the engine's difference score (0 = identical,
    /// up to the configured max of 40; default threshold is 5).
    case similarImage(width: Int, height: Int, difference: Int)
    /// Similar music: tags and format metadata from the engine.
    case similarMusic(title: String, artist: String, lengthSeconds: Int, bitrateKbps: Int)
    /// Similar video: dimensions plus metadata the engine extracted via ffmpeg.
    case similarVideo(width: Int, height: Int, durationSeconds: Double, codec: String)
    /// Symlink whose target does not exist.
    case invalidSymlink(destination: String, error: String)
    /// File that failed one or more integrity checks; keys are the engine's check
    /// names (e.g. "Pdf", "Image"), values are its messages.
    case brokenFile(errors: [String: String])
    /// File whose content type disagrees with its extension.
    case wrongExtension(current: String, proper: String)
    /// File name the engine's checks flag; `suggested` is the fixed name it proposes
    /// (reported only; SuperClean never applies fixes in place).
    case badName(suggested: String)
}

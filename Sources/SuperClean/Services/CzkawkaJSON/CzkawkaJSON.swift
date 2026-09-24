import Foundation

// MARK: - CzkawkaJSON
// Parses the single JSON document czkawka_cli writes to the `-p` file.
//
// Every shape below was verified against REAL output of the pinned binary
// (Engines/czkawka_cli, czkawka 12.0.2) captured in Tests/Fixtures/czkawka/:
//
//   dup HASH        { "<size>": [ [ {path, modified_date, size, hash}, ... ], ... ] }
//   dup SIZE        { "<size>": [ {path, modified_date, size, hash:""}, ... ] }
//   dup NAME        { "<name>": [ {path, modified_date, size, hash:""}, ... ] }
//   dup SIZE_NAME   [ [ {path, modified_date, size, hash:""}, ... ], ... ]  <- bare array,
//                   no keys at all (the serializer drops the map's tuple keys); empty = []
//   empty-folders   [ "/abs/path", ... ]
//   big             [ {path, size, modified_date}, ... ]          (size desc, zero-byte excluded)
//   empty-files     [ {path, size, modified_date}, ... ]
//   temp            [ {path, modified_date, size}, ... ]
//   image           [ [ {path, size, width, height, modified_date, hashes:[], difference}, ... ], ... ]
//   music           [ [ {size, path, modified_date, fingerprint:[], track_title, track_artist,
//                        year, length, genre, bitrate}, ... ], ... ]
//   video           [ [ {path, size, modified_date, signature:{...}, error, fps, codec,
//                        bitrate, width, height, duration}, ... ], ... ]
//   symlinks        [ {path, size, modified_date, symlink_info:{destination_path, type_of_error}}, ... ]
//   broken          [ {path, modified_date, size, errors:{<check type>: <message>}}, ... ]
//   ext             [ {path, modified_date, size, current_extension, proper_extensions_group,
//                       proper_extension}, ... ]
//   bad-names       [ {path, modified_date, size, new_name}, ... ]   (requires check flags, see
//                   CzkawkaTool.extraClapFlags; -F fix flags exist but are never used here)
//
// Field order differs per tool; numbers arrive as NSNumber (JSONSerialization), so the
// helpers coerce. No category/reason fields exist anywhere: Swift supplies those.

/// Typed parse failure. Never silent: a scan whose JSON cannot be parsed raises, it
/// does not pretend to have found nothing.
public enum CzkawkaJSONError: Error, Equatable, Sendable, LocalizedError {
    /// The file did not contain valid JSON at all.
    case unparseable
    /// Valid JSON, but not the shape the tool is documented to write. `detail` names
    /// what was expected and what was found.
    case unexpectedShape(detail: String)

    public var errorDescription: String? {
        switch self {
        case .unparseable: "czkawka output is not valid JSON"
        case .unexpectedShape(let detail): "unexpected czkawka JSON shape: \(detail)"
        }
    }
}

/// Stateless parser over one czkawka JSON document.
public enum CzkawkaJSON {

    // MARK: Public API

    /// Walk one JSON document and call `body` per item, in engine order (groups stay
    /// adjacent, big stays sorted). The whole decoded tree lives in memory only while
    /// `body` runs, and items are handed out one at a time, so a caller can stream them
    /// straight into a lazy list without ever building a full `[CzkawkaItem]`.
    /// Throws `CzkawkaJSONError` on unparseable input or a wrong top-level shape.
    /// Malformed INDIVIDUAL entries (e.g. missing path) are skipped, never fatal.
    public static func forEachItem(
        in data: Data,
        tool: CzkawkaTool,
        dupSearchMethod: CzkawkaDupSearchMethod = .hash,
        _ body: (CzkawkaItem) throws -> Void
    ) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CzkawkaJSONError.unparseable
        }
        switch tool {
        case .duplicates:
            try forEachDuplicate(in: object, method: dupSearchMethod, body)
        case .emptyFolders:
            try forEachFolder(in: object, body)
        case .bigFiles, .emptyFiles, .temporaryFiles:
            try forEachFile(in: object, tool: tool, body)
        case .invalidSymlinks, .brokenFiles, .wrongExtensions, .badNames:
            try forEachInspectedFile(in: object, tool: tool, body)
        case .similarImages, .similarMusic, .similarVideos:
            try forEachGroup(in: object, tool: tool, body)
        }
    }

    /// Convenience for tests and small scans: collect every item into an array.
    public static func items(
        in data: Data,
        tool: CzkawkaTool,
        dupSearchMethod: CzkawkaDupSearchMethod = .hash
    ) throws -> [CzkawkaItem] {
        var result: [CzkawkaItem] = []
        try forEachItem(in: data, tool: tool, dupSearchMethod: dupSearchMethod) {
            result.append($0)
        }
        return result
    }

    // MARK: dup (four shapes)

    private static func forEachDuplicate(
        in object: Any,
        method: CzkawkaDupSearchMethod,
        _ body: (CzkawkaItem) throws -> Void
    ) throws {
        switch method {
        case .sizeName:
            // Verified: bare array of groups, keys dropped by the serializer.
            guard let groups = object as? [Any] else {
                throw CzkawkaJSONError.unexpectedShape(
                    detail: "dup -s SIZE_NAME must be an array of groups, got \(typeName(of: object))"
                )
            }
            for (index, rawGroup) in groups.enumerated() {
                let entries = normalizeGroup(rawGroup)
                guard !entries.isEmpty else { continue }
                let groupID = synthesizedSizeNameGroupID(from: entries) ?? "group:\(index + 1)"
                for entry in entries {
                    guard let item = duplicateItem(from: entry, groupID: groupID) else { continue }
                    try body(item)
                }
            }
        case .hash:
            // Verified: object keyed by size string; each value is an array of groups.
            guard let bySize = object as? [String: Any] else {
                throw CzkawkaJSONError.unexpectedShape(
                    detail: "dup -s HASH must be an object keyed by size, got \(typeName(of: object))"
                )
            }
            for (sizeKey, value) in bySize {
                for rawGroup in normalizeGroups(value) {
                    let entries = normalizeGroup(rawGroup)
                    guard !entries.isEmpty else { continue }
                    let groupID = duplicateGroupID(entries: entries, fallback: "size:\(sizeKey)")
                    for entry in entries {
                        guard let item = duplicateItem(from: entry, groupID: groupID) else { continue }
                        try body(item)
                    }
                }
            }
        case .size, .name:
            // Verified: object keyed by size/name string; value is ONE flat entry array.
            let keyKind = method == .size ? "size" : "name"
            guard let map = object as? [String: Any] else {
                throw CzkawkaJSONError.unexpectedShape(
                    detail: "dup -s \(method.clapValue) must be an object keyed by \(keyKind), got \(typeName(of: object))"
                )
            }
            for (key, value) in map {
                for rawGroup in normalizeGroups(value) {
                    let entries = normalizeGroup(rawGroup)
                    guard !entries.isEmpty else { continue }
                    let groupID = "\(keyKind):\(key)"
                    for entry in entries {
                        guard let item = duplicateItem(from: entry, groupID: groupID) else { continue }
                        try body(item)
                    }
                }
            }
        }
    }

    /// Accepts either `[[entry...]...]` (HASH) or `[entry...]` (SIZE/NAME) so a parser
    /// written for one shape still reads the other. Returns the list of groups.
    private static func normalizeGroups(_ value: Any) -> [Any] {
        guard let array = value as? [Any] else { return [] }
        guard let first = array.first else { return [] }
        return first is [String: Any] ? [array] : array
    }

    /// Accepts a group as `[entry...]`; entries must be dictionaries.
    private static func normalizeGroup(_ raw: Any) -> [[String: Any]] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    private static func duplicateGroupID(entries: [[String: Any]], fallback: String) -> String {
        // HASH mode: every entry in a group shares the content hash.
        if let hash = string(entries[0]["hash"]), !hash.isEmpty { return "hash:\(hash)" }
        return fallback
    }

    /// SIZE_NAME drops the map keys entirely, so rebuild them from the first entry:
    /// the key was a (size, name) tuple.
    private static func synthesizedSizeNameGroupID(from entries: [[String: Any]]) -> String? {
        guard let first = entries.first,
              let size = int64(first["size"]),
              let path = string(first["path"])
        else { return nil }
        return "size_name:\(size):\((path as NSString).lastPathComponent)"
    }

    private static func duplicateItem(from entry: [String: Any], groupID: String) -> CzkawkaItem? {
        guard let path = string(entry["path"]) else { return nil }
        let hash = string(entry["hash"]) ?? ""
        return CzkawkaItem(
            path: path,
            sizeBytes: int64(entry["size"]) ?? 0,
            tool: .duplicates,
            groupID: groupID,
            detail: .duplicate(hash: hash)
        )
    }

    // MARK: empty-folders

    private static func forEachFolder(
        in object: Any,
        _ body: (CzkawkaItem) throws -> Void
    ) throws {
        guard let folders = object as? [Any] else {
            throw CzkawkaJSONError.unexpectedShape(
                detail: "empty-folders must be an array of path strings, got \(typeName(of: object))"
            )
        }
        for raw in folders {
            guard let path = raw as? String else { continue }
            try body(CzkawkaItem(path: path, sizeBytes: 0, tool: .emptyFolders))
        }
    }

    // MARK: flat file tools (big, empty-files, temp)

    private static func forEachFile(
        in object: Any,
        tool: CzkawkaTool,
        _ body: (CzkawkaItem) throws -> Void
    ) throws {
        guard let files = object as? [Any] else {
            throw CzkawkaJSONError.unexpectedShape(
                detail: "\(tool.clapName) must be an array of file entries, got \(typeName(of: object))"
            )
        }
        for raw in files {
            guard let entry = raw as? [String: Any], let path = string(entry["path"]) else { continue }
            try body(CzkawkaItem(path: path, sizeBytes: int64(entry["size"]) ?? 0, tool: tool))
        }
    }

    // MARK: flat inspected-file tools (symlinks, broken, ext, bad-names)

    private static func forEachInspectedFile(
        in object: Any,
        tool: CzkawkaTool,
        _ body: (CzkawkaItem) throws -> Void
    ) throws {
        guard let files = object as? [Any] else {
            throw CzkawkaJSONError.unexpectedShape(
                detail: "\(tool.clapName) must be an array of file entries, got \(typeName(of: object))"
            )
        }
        for raw in files {
            guard let entry = raw as? [String: Any], let path = string(entry["path"]) else { continue }
            let size = int64(entry["size"]) ?? 0
            let detail: CzkawkaItemDetail
            switch tool {
            case .invalidSymlinks:
                let info = entry["symlink_info"] as? [String: Any] ?? [:]
                detail = .invalidSymlink(
                    destination: string(info["destination_path"]) ?? "",
                    error: string(info["type_of_error"]) ?? ""
                )
            case .brokenFiles:
                detail = .brokenFile(errors: entry["errors"] as? [String: String] ?? [:])
            case .wrongExtensions:
                detail = .wrongExtension(
                    current: string(entry["current_extension"]) ?? "",
                    proper: string(entry["proper_extension"]) ?? ""
                )
            case .badNames:
                detail = .badName(suggested: string(entry["new_name"]) ?? "")
            default:
                return
            }
            try body(CzkawkaItem(path: path, sizeBytes: size, tool: tool, detail: detail))
        }
    }

    // MARK: grouped media tools (image, music, video)

    private static func forEachGroup(
        in object: Any,
        tool: CzkawkaTool,
        _ body: (CzkawkaItem) throws -> Void
    ) throws {
        guard let groups = object as? [Any] else {
            throw CzkawkaJSONError.unexpectedShape(
                detail: "\(tool.clapName) must be an array of groups, got \(typeName(of: object))"
            )
        }
        for (index, rawGroup) in groups.enumerated() {
            let entries = normalizeGroup(rawGroup)
            guard !entries.isEmpty else { continue }
            let groupID = "group:\(index + 1)"
            for entry in entries {
                guard let item = mediaItem(from: entry, tool: tool, groupID: groupID) else { continue }
                try body(item)
            }
        }
    }

    private static func mediaItem(from entry: [String: Any], tool: CzkawkaTool, groupID: String) -> CzkawkaItem? {
        guard let path = string(entry["path"]) else { return nil }
        let size = int64(entry["size"]) ?? 0
        let detail: CzkawkaItemDetail
        switch tool {
        case .similarImages:
            detail = .similarImage(
                width: int(entry["width"]) ?? 0,
                height: int(entry["height"]) ?? 0,
                difference: int(entry["difference"]) ?? 0
            )
        case .similarMusic:
            detail = .similarMusic(
                title: string(entry["track_title"]) ?? "",
                artist: string(entry["track_artist"]) ?? "",
                lengthSeconds: int(entry["length"]) ?? 0,
                bitrateKbps: int(entry["bitrate"]) ?? 0
            )
        case .similarVideos:
            detail = .similarVideo(
                width: int(entry["width"]) ?? 0,
                height: int(entry["height"]) ?? 0,
                durationSeconds: double(entry["duration"]) ?? 0,
                codec: string(entry["codec"]) ?? ""
            )
        default:
            return nil
        }
        return CzkawkaItem(path: path, sizeBytes: size, tool: tool, groupID: groupID, detail: detail)
    }

    // MARK: JSON number coercion (JSONSerialization hands back NSNumber everywhere)

    private static func string(_ any: Any?) -> String? { any as? String }
    private static func int64(_ any: Any?) -> Int64? { (any as? NSNumber)?.int64Value }
    private static func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }
    private static func double(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    private static func typeName(of object: Any) -> String {
        String(describing: type(of: object))
    }
}

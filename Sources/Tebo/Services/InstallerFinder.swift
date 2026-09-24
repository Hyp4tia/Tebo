import Foundation

// MARK: - InstallerFinder
// Stray installer discovery, ported from Mole's `mo installer` command
// (bin/installer.sh). Finds .dmg/.pkg/.mpkg/.iso/.xip files in the usual
// download locations, plus .zip files that CONTAIN an installer payload
// (Mole's is_installer_zip, installer.sh:68-84) - a plain archive of
// documents is not an installer and must not be offered as one. Find-only:
// nothing here can delete; removal goes through DeletePipeline elsewhere.

// MARK: Models

/// What kind of installer artifact this file is.
public enum InstallerKind: String, Sendable, Equatable, CaseIterable {
    case diskImage = "dmg"
    case package = "pkg"
    case metapackage = "mpkg"
    case isoArchive = "iso"
    case xipArchive = "xip"
    /// A .zip that contains an installer payload (app/pkg/dmg/xip entry).
    case zipPayload = "zip"
}

/// One installer file the Apps/Disk tab shows. Zero-size files are still
/// reported - Mole lists them too - but size stays honest (0).
public struct InstallerFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let sizeBytes: Int64
    /// File mtime; nil only when the attributes cannot be read.
    public let lastModified: Date?
    public let kind: InstallerKind
    /// Friendly source location, e.g. "Downloads" (Mole
    /// get_source_display, installer.sh:153-171).
    public let source: String

    public init(
        id: UUID = UUID(),
        path: String,
        sizeBytes: Int64,
        lastModified: Date?,
        kind: InstallerKind,
        source: String
    ) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.kind = kind
        self.source = source
    }

    public var name: String {
        (path as NSString).lastPathComponent
    }

    /// Seconds since lastModified; nil when unknown. A nil age means the
    /// UI shows "unavailable", never a made-up number.
    public var age: TimeInterval? {
        lastModified.map { max(0, Date().timeIntervalSince($0)) }
    }

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: Configuration

/// Scan settings; tests pass fixture roots so the real home is untouched.
public struct InstallerScanConfiguration: Sendable, Equatable {
    public var searchRoots: [String]
    /// Mole INSTALLER_SCAN_MAX_DEPTH_DEFAULT = 2 (installer.sh:39): direct
    /// children plus one level of subdirectories.
    public var maxDepth: Int
    /// Whether .zip files get the payload-content check (Mole
    /// is_installer_zip). When false, zips are never reported.
    public var inspectZipPayloads: Bool

    public init(
        searchRoots: [String],
        maxDepth: Int = 2,
        inspectZipPayloads: Bool = true
    ) {
        self.searchRoots = searchRoots
        self.maxDepth = maxDepth
        self.inspectZipPayloads = inspectZipPayloads
    }

    /// Mole's INSTALLER_SCAN_PATHS (bin/installer.sh:40-53). Missing roots
    /// are skipped silently, exactly like the bash `[[ -d "$path" ]]`
    /// guard.
    public static func defaults(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> InstallerScanConfiguration {
        let h = home as NSString
        func joined(_ relative: String) -> String { h.appendingPathComponent(relative) }
        return InstallerScanConfiguration(
            searchRoots: [
                joined("Downloads"),
                joined("Desktop"),
                joined("Documents"),
                joined("Public"),
                joined("Library/Downloads"),
                "/Users/Shared",
                "/Users/Shared/Downloads",
                joined("Library/Caches/Homebrew"),
                joined("Library/Mobile Documents/com~apple~CloudDocs/Downloads"),
                joined("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                joined("Library/Application Support/Telegram Desktop"),
                joined("Downloads/Telegram Desktop"),
            ],
            maxDepth: 2,
            inspectZipPayloads: true
        )
    }
}

// MARK: Zip payload inspection

/// Seam that makes zip-content checks fakeable and keeps them out of the
/// scan loop.
public protocol ZipPayloadInspecting: Sendable {
    /// True when the zip's entry list (first 50 entries, like Mole's
    /// `zipinfo -1 | head -n 50`) contains an installer payload name.
    func containsInstallerPayload(zipPath: String) -> Bool
}

/// Native central-directory scan, no zip library. Reads only the End Of
/// Central Directory record and the entry names - exactly the information
/// Mole's zipinfo -1 uses. Fails closed: malformed data, a zip64 marker,
/// or an unreadable file returns false, so a zip is only ever reported as
/// an installer on positive evidence.
public struct NativeZipPayloadInspector: ZipPayloadInspecting {
    /// Mole MAX_ZIP_ENTRIES (bin/installer.sh:54).
    private static let maxEntries = 50
    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50

    public init() {}

    public func containsInstallerPayload(zipPath: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: zipPath)),
              let fileSize = try? handle.seekToEnd(),
              fileSize >= 22 else { return false }
        // The EOCD sits at the end, possibly behind a comment (zip allows
        // up to 65535 comment bytes).
        let windowStart = fileSize - min(fileSize, UInt64(22 + 65_535))
        guard (try? handle.seek(toOffset: windowStart)) != nil,
              let window = try? handle.readToEnd() else { return false }
        return Self.scanCentralDirectory(window: window, fileSize: fileSize, handle: handle)
    }

    private static func scanCentralDirectory(
        window: Data,
        fileSize: UInt64,
        handle: FileHandle
    ) -> Bool {
        guard let eocdIndex = lastIndexOf(signature: eocdSignature, in: window),
              window.count - eocdIndex >= 22 else { return false }
        let entryCount = window.le16(eocdIndex + 10)
        guard entryCount != 0xFFFF else { return false } // zip64: unknown layout, fail closed
        let cdSize = window.le32(eocdIndex + 12)
        let cdOffset = window.le32(eocdIndex + 16)
        guard UInt64(cdOffset) + UInt64(cdSize) <= fileSize,
              (try? handle.seek(toOffset: UInt64(cdOffset))) != nil,
              let central = try? handle.read(upToCount: Int(cdSize)),
              central.count == Int(cdSize) else { return false }
        return containsPayload(in: central, entryCount: Int(entryCount))
    }

    private static func containsPayload(in central: Data, entryCount: Int) -> Bool {
        // Mole caps the listing at 50 entries; a payload past that cap is
        // not seen, so it is not reported (installer.sh:67-84).
        let limit = min(entryCount, maxEntries)
        let pattern = try? NSRegularExpression(pattern: #"\.(app|pkg|dmg|xip)(/|$)"#)
        var cursor = 0
        for _ in 0..<limit {
            guard central.count - cursor >= 46,
                  central.le32(cursor) == centralSignature else { return false }
            let nameLength = Int(central.le16(cursor + 28))
            let extraLength = Int(central.le16(cursor + 30))
            let commentLength = Int(central.le16(cursor + 32))
            let nameStart = cursor + 46
            guard central.count - nameStart >= nameLength else { return false }
            let name = String(decoding: central[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            if let pattern,
               pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                return true
            }
            cursor = nameStart + nameLength + extraLength + commentLength
            guard cursor <= central.count else { return false }
        }
        return false
    }

    /// Last occurrence of a little-endian signature (EOCD), scanning
    /// backwards so a comment that happens to contain the magic bytes does
    /// not win over the real record.
    private static func lastIndexOf(signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.count - 4
        while index >= 0 {
            if data.le32(index) == signature { return index }
            index -= 1
        }
        return nil
    }
}

private extension Data {
    func le16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func le32(_ offset: Int) -> UInt32 {
        UInt32(le16(offset)) | (UInt32(le16(offset + 2)) << 16)
    }
}

// MARK: Service

/// The finder the Apps/Disk tab calls. Injectable configuration and zip
/// inspector keep tests on fixture trees only.
public struct InstallerFinder: Sendable {
    public let configuration: InstallerScanConfiguration
    private let zipInspector: any ZipPayloadInspecting

    public init(
        configuration: InstallerScanConfiguration = .defaults(),
        zipInspector: any ZipPayloadInspecting = NativeZipPayloadInspector()
    ) {
        self.configuration = configuration
        self.zipInspector = zipInspector
    }

    public func findInstallers() async -> [InstallerFile] {
        var results: [InstallerFile] = []
        for root in configuration.searchRoots {
            if Task.isCancelled || results.count >= 1000 { break }
            results += scan(root: root, fileDepth: 1)
        }
        // Biggest first, like the rest of the app's scan rows.
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Traversal helper. Internal (not private) so the depth/symlink/zip
    /// rules are unit-testable. `fileDepth` is the depth of the entries
    /// about to be examined (1 = direct children of a search root),
    /// mirroring `find -maxdepth 2`: files at depth 1 and 2 are seen,
    /// deeper ones are not (Mole INSTALLER_SCAN_MAX_DEPTH_DEFAULT,
    /// installer.sh:39).
    func scan(root: String, fileDepth: Int) -> [InstallerFile] {
        var results: [InstallerFile] = []
        guard fileDepth <= configuration.maxDepth else { return results }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            .volumeIsLocalKey,
        ]
        let url = URL(fileURLWithPath: root, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: []
        ) else { return results }

        for child in children {
            if Task.isCancelled || results.count >= 1000 { break }
            guard let values = try? child.resourceValues(forKeys: keys) else { continue }
            // Mole skips symlinks explicitly (installer.sh:89): a symlinked
            // installer is usually a mounted/copied artifact, and following
            // links could escape the searched roots.
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                // A mounted volume (network share, disk image) under a
                // download location is not a stray installer and walking
                // it could cross into a remote filesystem: never descend.
                if values.volumeIsLocal == false { continue }
                results += scan(root: child.path, fileDepth: fileDepth + 1)
                continue
            }
            let ext = child.pathExtension.lowercased()
            guard let kind = Self.kind(forExtension: ext) else { continue }
            if kind == .zipPayload {
                // Plain zips are only installers with positive payload
                // evidence (Mole is_installer_zip, installer.sh:68-84).
                guard configuration.inspectZipPayloads,
                      zipInspector.containsInstallerPayload(zipPath: child.path) else { continue }
            }
            results.append(InstallerFile(
                path: child.path,
                sizeBytes: Int64(values.fileSize ?? 0),
                lastModified: values.contentModificationDate,
                kind: kind,
                source: Self.sourceLabel(for: child.path, home: FileManager.default.homeDirectoryForCurrentUser.path)
            ))
        }
        return results
    }

    /// Extension -> row kind (Mole handle_candidate_file,
    /// installer.sh:91-100: dmg/pkg/mpkg/iso/xip always, zip conditional).
    static func kind(forExtension ext: String) -> InstallerKind? {
        switch ext {
        case "dmg": return .diskImage
        case "pkg": return .package
        case "mpkg": return .metapackage
        case "iso": return .isoArchive
        case "xip": return .xipArchive
        case "zip": return .zipPayload
        default: return nil
        }
    }

    /// Friendly source name (Mole get_source_display, installer.sh:153-171).
    static func sourceLabel(for path: String, home: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let h = home as NSString
        func under(_ relative: String) -> Bool {
            let prefix = h.appendingPathComponent(relative)
            return dir == prefix || dir.hasPrefix(prefix + "/")
        }
        if under("Downloads") { return "Downloads" }
        if under("Desktop") { return "Desktop" }
        if under("Documents") { return "Documents" }
        if under("Public") { return "Public" }
        if under("Library/Downloads") { return "Library" }
        if dir == "/Users/Shared" || dir.hasPrefix("/Users/Shared/") { return "Shared" }
        if under("Library/Caches/Homebrew") { return "Homebrew" }
        if under("Library/Mobile Documents/com~apple~CloudDocs/Downloads") { return "iCloud" }
        if under("Library/Containers/com.apple.mail") { return "Mail" }
        if dir.contains("Telegram Desktop") { return "Telegram" }
        return (dir as NSString).lastPathComponent
    }
}

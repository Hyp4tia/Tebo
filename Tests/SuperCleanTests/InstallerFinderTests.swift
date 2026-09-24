import Foundation
import Testing
@testable import SuperClean

// MARK: - InstallerFinder tests
// All scans run against fixture trees under a temp directory; the real
// Downloads/Desktop are never touched. Zips are built byte-by-byte in the
// test file (STORE method, no compression) so the native central-directory
// inspector is exercised against real zip layout.

@Suite("InstallerFinder")
struct InstallerFinderTests {

    // MARK: Zip fixture builder

    struct ZipEntry {
        let name: String
        let data: Data
    }

    /// Minimal valid zip: STORE method, zero CRC (the inspector reads only
    /// entry names, like Mole's zipinfo -1).
    enum ZipBuilder {
        static func build(entries: [ZipEntry]) -> Data {
            var body = Data()
            var central = Data()
            var offset: UInt32 = 0
            for entry in entries {
                let name = Data(entry.name.utf8)
                var local = Data()
                local.append(le32(0x0403_4B50))
                local.append(le16(20)) // version needed
                local.append(le16(0)) // flags
                local.append(le16(0)) // method: store
                local.append(le16(0)) // mod time
                local.append(le16(0)) // mod date
                local.append(le32(0)) // crc32 (not validated by the inspector)
                let size = UInt32(entry.data.count)
                local.append(le32(size))
                local.append(le32(size))
                local.append(le16(UInt16(name.count)))
                local.append(le16(0)) // extra length
                local.append(name)
                body.append(local)
                body.append(entry.data)

                var header = Data()
                header.append(le32(0x0201_4B50))
                header.append(le16(20)) // version made by
                header.append(le16(20)) // version needed
                header.append(le16(0)) // flags
                header.append(le16(0)) // method
                header.append(le16(0)) // time
                header.append(le16(0)) // date
                header.append(le32(0)) // crc
                header.append(le32(size))
                header.append(le32(size))
                header.append(le16(UInt16(name.count)))
                header.append(le16(0)) // extra length
                header.append(le16(0)) // comment length
                header.append(le16(0)) // disk number
                header.append(le16(0)) // internal attrs
                header.append(le32(0)) // external attrs
                header.append(le32(offset))
                header.append(name)
                central.append(header)

                offset += UInt32(local.count + entry.data.count)
            }
            var eocd = Data()
            eocd.append(le32(0x0605_4B50))
            eocd.append(le16(0)) // disk
            eocd.append(le16(0)) // cd start disk
            eocd.append(le16(UInt16(entries.count)))
            eocd.append(le16(UInt16(entries.count)))
            eocd.append(le32(UInt32(central.count)))
            eocd.append(le32(UInt32(body.count)))
            eocd.append(le16(0)) // comment length
            return body + central + eocd
        }

        static func le16(_ value: UInt16) -> Data {
            var copy = value.littleEndian
            return Data(bytes: &copy, count: 2)
        }

        static func le32(_ value: UInt32) -> Data {
            var copy = value.littleEndian
            return Data(bytes: &copy, count: 4)
        }
    }

    // MARK: Fixture helpers

    struct Fixture {
        let root: URL
        /// Outer unique dir; removing it cleans up the whole tree even
        /// though `root` (the leaf) carries the meaningful name.
        let cleanupURL: URL

        init(directoryName: String) throws {
            let outer = FileManager.default.temporaryDirectory
                .appendingPathComponent("InstallerFinderTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
            // The leaf keeps the plain name ("Downloads") so the source
            // label falls back to exactly the label Mole's real-root
            // mapping produces.
            let root = outer.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.cleanupURL = outer
            self.root = root
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: cleanupURL)
        }

        @discardableResult
        func write(_ bytes: Int, named name: String, relative: String = "") throws -> URL {
            let url = root.appendingPathComponent(relative).appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: url)
            return url
        }

        func write(_ data: Data, named name: String, relative: String = "") throws -> URL {
            let url = root.appendingPathComponent(relative).appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
            return url
        }

        func finder(maxDepth: Int = 2, inspectZipPayloads: Bool = true) -> InstallerFinder {
            InstallerFinder(
                configuration: InstallerScanConfiguration(
                    searchRoots: [root.path],
                    maxDepth: maxDepth,
                    inspectZipPayloads: inspectZipPayloads
                )
            )
        }
    }

    @Test("Finds dmg/pkg/mpkg/iso/xip with size and metadata")
    func findsStandardInstallers() async throws {
        let fixture = try Fixture(directoryName: "Downloads")
        defer { fixture.tearDown() }
        try fixture.write(10, named: "FakeTool.dmg")
        try fixture.write(20, named: "Setup.pkg")
        try fixture.write(30, named: "Combo.mpkg")
        try fixture.write(40, named: "Disk.iso")
        try fixture.write(50, named: "Update.xip")
        try fixture.write(60, named: "notes.txt") // never an installer

        let rows = await fixture.finder().findInstallers()

        #expect(rows.count == 5)
        let byKind = Dictionary(grouping: rows, by: \.kind)
        #expect(byKind[.diskImage]?.count == 1)
        #expect(byKind[.package]?.count == 1)
        #expect(byKind[.metapackage]?.count == 1)
        #expect(byKind[.isoArchive]?.count == 1)
        #expect(byKind[.xipArchive]?.count == 1)
        let dmg = try #require(rows.first { $0.name == "FakeTool.dmg" })
        #expect(dmg.sizeBytes == 10)
        #expect(dmg.lastModified != nil)
        #expect(dmg.age != nil)
        #expect(dmg.age! >= 0)
        // Fixture dir is named "Downloads", so the fallback label reads
        // "Downloads" exactly like Mole's real-root mapping.
        #expect(dmg.source == "Downloads")
        #expect(rows.allSatisfy { $0.source == "Downloads" })
    }

    @Test("Depth limit matches Mole's max-depth 2")
    func depthLimitIsTwo() async throws {
        let fixture = try Fixture(directoryName: "Downloads")
        defer { fixture.tearDown() }
        try fixture.write(10, named: "root.pkg")
        try fixture.write(10, named: "level2.dmg", relative: "sub")
        try fixture.write(10, named: "too-deep.pkg", relative: "sub/sub2")
        // A pathological chain: an installer buried 20 levels down must
        // not be found, and - more importantly - the scan must RETURN
        // instead of walking the chain forever.
        var deepPath = "sub"
        for _ in 0..<20 { deepPath += "/sub" }
        try fixture.write(10, named: "bottom.pkg", relative: deepPath)

        let rows = await fixture.finder().findInstallers()

        let names = Set(rows.map(\.name))
        #expect(names.contains("root.pkg"))
        #expect(names.contains("level2.dmg"))
        #expect(!names.contains("too-deep.pkg"))
        #expect(!names.contains("bottom.pkg"))
        #expect(rows.count == 2)
    }

    @Test("Zips need positive installer payload evidence")
    func zipsNeedPayloadEvidence() async throws {
        let fixture = try Fixture(directoryName: "Downloads")
        defer { fixture.tearDown() }
        let notes = ZipBuilder.build(entries: [
            ZipEntry(name: "readme.txt", data: Data("hello".utf8)),
            ZipEntry(name: "data.bin", data: Data(count: 4)),
        ])
        try fixture.write(notes, named: "notes.zip")
        let appZip = ZipBuilder.build(entries: [
            ZipEntry(name: "Foo.app/Contents/Info.plist", data: Data("x".utf8)),
        ])
        try fixture.write(appZip, named: "App.zip")
        let pkgZip = ZipBuilder.build(entries: [
            ZipEntry(name: "Setup.pkg", data: Data(count: 8)),
        ])
        try fixture.write(pkgZip, named: "pkginside.zip")

        let rows = await fixture.finder().findInstallers()

        let names = Set(rows.map(\.name))
        #expect(!names.contains("notes.zip"))
        #expect(names.contains("App.zip"))
        #expect(names.contains("pkginside.zip"))
        let appRow = try #require(rows.first { $0.name == "App.zip" })
        #expect(appRow.kind == .zipPayload)
    }

    @Test("Zip inspector fails closed on garbage input")
    func inspectorFailsClosedOnGarbage() throws {
        let fixture = try Fixture(directoryName: "garbage")
        defer { fixture.tearDown() }
        let inspector = NativeZipPayloadInspector()

        let empty = try fixture.write(Data(), named: "empty.zip")
        #expect(inspector.containsInstallerPayload(zipPath: empty.path) == false)

        let random = try fixture.write(Data(count: 100), named: "random.zip")
        #expect(inspector.containsInstallerPayload(zipPath: random.path) == false)

        let valid = ZipBuilder.build(entries: [ZipEntry(name: "Foo.app/", data: Data())])
        let truncated = valid.prefix(valid.count - 10)
        let partial = try fixture.write(Data(truncated), named: "truncated.zip")
        #expect(inspector.containsInstallerPayload(zipPath: partial.path) == false)

        let real = try fixture.write(valid, named: "real.zip")
        #expect(inspector.containsInstallerPayload(zipPath: real.path) == true)

        let missing = fixture.root.appendingPathComponent("missing.zip").path
        #expect(inspector.containsInstallerPayload(zipPath: missing) == false)
    }

    @Test("Zip inspector honors Mole's 50-entry cap")
    func inspectorHonorsEntryCap() throws {
        let fixture = try Fixture(directoryName: "cap")
        defer { fixture.tearDown() }
        let inspector = NativeZipPayloadInspector()

        var latePayload = (0..<59).map {
            ZipEntry(name: "file\($0).txt", data: Data(count: 1))
        }
        latePayload.append(ZipEntry(name: "Late.app/", data: Data()))
        let lateZip = try fixture.write(ZipBuilder.build(entries: latePayload), named: "late.zip")
        #expect(inspector.containsInstallerPayload(zipPath: lateZip.path) == false)

        var earlyPayload = (0..<4).map {
            ZipEntry(name: "file\($0).txt", data: Data(count: 1))
        }
        earlyPayload.insert(ZipEntry(name: "Early.pkg", data: Data()), at: 2)
        let earlyZip = try fixture.write(ZipBuilder.build(entries: earlyPayload), named: "early.zip")
        #expect(inspector.containsInstallerPayload(zipPath: earlyZip.path) == true)
    }

    @Test("Skips symlinks like Mole")
    func skipsSymlinks() async throws {
        let fixture = try Fixture(directoryName: "Downloads")
        defer { fixture.tearDown() }
        let target = try fixture.write(10, named: "real.dmg")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("Link.dmg"),
            withDestinationURL: target
        )

        let rows = await fixture.finder().findInstallers()

        let names = Set(rows.map(\.name))
        #expect(names.contains("real.dmg"))
        #expect(!names.contains("Link.dmg"))
    }

    @Test("Zip inspection can be disabled")
    func zipInspectionToggle() async throws {
        let fixture = try Fixture(directoryName: "Downloads")
        defer { fixture.tearDown() }
        let appZip = ZipBuilder.build(entries: [ZipEntry(name: "Foo.app/", data: Data())])
        try fixture.write(appZip, named: "App.zip")
        try fixture.write(10, named: "Real.dmg")

        let rows = await fixture.finder(inspectZipPayloads: false).findInstallers()

        let names = Set(rows.map(\.name))
        #expect(!names.contains("App.zip"))
        #expect(names.contains("Real.dmg"))
    }

    @Test("Source labels mirror Mole's get_source_display")
    func sourceLabelMapping() {
        let home = "/Users/alice"
        func label(_ path: String) -> String {
            InstallerFinder.sourceLabel(for: path, home: home)
        }
        #expect(label(home + "/Downloads/x.dmg") == "Downloads")
        #expect(label(home + "/Desktop/x.dmg") == "Desktop")
        #expect(label(home + "/Documents/x.dmg") == "Documents")
        #expect(label(home + "/Public/x.dmg") == "Public")
        #expect(label(home + "/Library/Downloads/x.dmg") == "Library")
        #expect(label("/Users/Shared/x.dmg") == "Shared")
        #expect(label("/Users/Shared/Downloads/x.dmg") == "Shared")
        #expect(label(home + "/Library/Caches/Homebrew/x.dmg") == "Homebrew")
        #expect(label(home + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads/x.dmg") == "iCloud")
        #expect(label(home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/x.dmg") == "Mail")
        #expect(label(home + "/Library/Application Support/Telegram Desktop/x.dmg") == "Telegram")
        #expect(label("/tmp/somewhere/else/x.dmg") == "else")
    }
}

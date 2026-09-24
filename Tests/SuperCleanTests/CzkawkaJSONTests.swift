import Foundation
import Testing
@testable import SuperClean

// MARK: - CzkawkaJSON tests
// Every assertion here is pinned to the REAL output of the bundled engine
// (Engines/czkawka_cli 12.0.2) captured in Tests/Fixtures/czkawka/. The counts and
// group structures below describe those committed files, not guessed schemas.

@Suite("CzkawkaJSON")
struct CzkawkaJSONTests {

    /// Tests/SuperCleanTests/.. -> Tests/Fixtures/czkawka
    private static let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/czkawka", isDirectory: true)

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesRoot.appendingPathComponent(name))
    }

    private func parse(_ name: String, tool: CzkawkaTool, method: CzkawkaDupSearchMethod = .hash) throws -> [CzkawkaItem] {
        try CzkawkaJSON.items(in: data(name), tool: tool, dupSearchMethod: method)
    }

    // MARK: dup, all four search methods (four verified shapes)

    @Test("dup HASH: object keyed by size, nested groups, hash group IDs")
    func dupHashFixture() throws {
        let items = try parse("dup.json", tool: .duplicates)
        // 5 size keys, 11 entries: 2 + 3 + 2 + 2 + 2.
        #expect(items.count == 11)
        let groups = Dictionary(grouping: items, by: { $0.groupID })
        #expect(groups.count == 5)
        #expect(groups.values.map(\.count).sorted() == [2, 2, 2, 2, 3])
        for item in items {
            guard case .duplicate(let hash) = item.detail else {
                Issue.record("dup HASH entry must carry a duplicate hash detail")
                continue
            }
            // Default hash type is BLAKE3: exactly 64 lowercase hex chars.
            #expect(hash.count == 64)
            let allHex = hash.allSatisfy(\.isHexDigit)
            #expect(allHex)
            #expect(item.groupID == "hash:\(hash)")
            #expect(item.tool == .duplicates)
            #expect(item.sizeBytes > 0)
            #expect(item.similarity == nil)
            #expect(item.dimensions == nil)
        }
    }

    @Test("dup SIZE: object keyed by size, flat entries, empty hashes")
    func dupSizeFixture() throws {
        let items = try parse("dup-size.json", tool: .duplicates, method: .size)
        // 6 size keys, 15 flat entries in the captured fixture.
        #expect(items.count == 15)
        let groups = Dictionary(grouping: items, by: { $0.groupID })
        #expect(groups.count == 6)
        for item in items {
            #expect(item.groupID?.hasPrefix("size:") == true)
            guard case .duplicate(let hash) = item.detail else {
                Issue.record("dup SIZE entry must carry a duplicate detail")
                continue
            }
            // SIZE never hashes: the engine writes the empty string, not a real hash.
            #expect(hash.isEmpty)
        }
    }

    @Test("dup NAME: object keyed by file name, flat entries")
    func dupNameFixture() throws {
        let items = try parse("dup-name.json", tool: .duplicates, method: .name)
        // 3 name keys (other.txt, report.txt, small.bin), 2 entries each.
        #expect(items.count == 6)
        let groups = Dictionary(grouping: items, by: { $0.groupID })
        #expect(groups.count == 3)
        #expect(groups.values.allSatisfy { $0.count == 2 })
        // Same name, different sizes still group (small.bin is 9216 + 10240 bytes).
        let smallGroup = groups["name:small.bin"]
        #expect(smallGroup?.map(\.sizeBytes).sorted() == [9216, 10240])
    }

    @Test("dup SIZE_NAME: bare array of groups, keys dropped by the serializer")
    func dupSizeNameFixture() throws {
        let items = try parse("dup-size-name.json", tool: .duplicates, method: .sizeName)
        // Two groups of two: the (size, name) map keys do not survive serialization,
        // so the parser rebuilds a stable group ID from size + file name.
        #expect(items.count == 4)
        let groups = Dictionary(grouping: items, by: { $0.groupID })
        #expect(groups.count == 2)
        let ids = groups.keys.compactMap { $0 }.sorted()
        #expect(ids.contains { $0.hasSuffix(":report.txt") })
        #expect(ids.contains { $0.hasSuffix(":other.txt") })
    }

    @Test("dup parses one shape even when the other search method is declared")
    func dupTolerantNesting() throws {
        // NAME output is flat per key; parsing it under HASH still reads every entry.
        let items = try parse("dup-name.json", tool: .duplicates, method: .hash)
        #expect(items.count == 6)
        // No real hashes in a NAME capture: group IDs fall back to the size key.
        #expect(items.allSatisfy { $0.groupID?.hasPrefix("size:") == true })
    }

    // MARK: flat tools

    @Test("empty-folders: array of path strings, zero bytes each")
    func emptyFoldersFixture() throws {
        let items = try parse("empty-folders.json", tool: .emptyFolders)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.sizeBytes == 0 && $0.detail == nil })
        // Engine order preserved: the deep folder first, then the plain empty dir.
        #expect(items[0].path.hasSuffix("deep"))
        #expect(items[1].path.hasSuffix("emptydir"))
        #expect(items[0].category == "Empty Folders")
    }

    @Test("big: flat entries, descending sizes preserved, zero-byte files excluded")
    func bigFixture() throws {
        let items = try parse("big.json", tool: .bigFiles)
        #expect(items.count == 25)
        let sizes = items.map(\.sizeBytes)
        #expect(sizes == sizes.sorted(by: >))
        #expect(sizes.allSatisfy { $0 > 0 })   // engine excludes empty files here
        #expect(items.allSatisfy { $0.tool == .bigFiles && $0.groupID == nil })
    }

    @Test("empty-files: flat entries with size 0")
    func emptyFilesFixture() throws {
        let items = try parse("empty-files.json", tool: .emptyFiles)
        #expect(items.count == 1)
        #expect(items[0].sizeBytes == 0)
        #expect(items[0].path.hasSuffix("empty.dat"))
        #expect(items[0].detail == nil)
    }

    @Test("temp: flat entries, default extension list")
    func tempFixture() throws {
        let items = try parse("temp.json", tool: .temporaryFiles)
        // backup.bak, draft.part, notes.tmp (editor.save is not on the default list).
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.sizeBytes == 512 })
        let names = items.map { ($0.path as NSString).lastPathComponent }.sorted()
        #expect(names == ["backup.bak", "draft.part", "notes.tmp"])
    }

    // MARK: grouped media tools

    @Test("image: groups of entries with dimensions and difference, hashes ignored")
    func imageFixture() throws {
        let items = try parse("image.json", tool: .similarImages)
        #expect(items.count == 2)
        #expect(Set(items.compactMap(\.groupID)).count == 1)
        for item in items {
            guard case .similarImage(let width, let height, let difference) = item.detail else {
                Issue.record("image entry must carry similarImage detail")
                continue
            }
            #expect(width == 1280)
            #expect(height == 960)
            #expect(difference == 0)
            // difference 0 = identical hash -> full similarity.
            #expect(item.similarity == 1.0)
            #expect(item.dimensions?.width == 1280 && item.dimensions?.height == 960)
        }
    }

    @Test("music: groups of entries with title/artist tags")
    func musicFixture() throws {
        let items = try parse("music.json", tool: .similarMusic)
        #expect(items.count == 3)
        #expect(Set(items.compactMap(\.groupID)).count == 1)
        for item in items {
            guard case .similarMusic(let title, let artist, let length, let bitrate) = item.detail else {
                Issue.record("music entry must carry similarMusic detail")
                continue
            }
            #expect(title == "Fixtune Alpha")
            #expect(artist == "Fixture Artist")
            #expect(length == 2)
            #expect(bitrate > 0)
        }
    }

    @Test("video: groups of entries with dimensions, duration and codec")
    func videoFixture() throws {
        let items = try parse("video.json", tool: .similarVideos)
        #expect(items.count == 2)
        #expect(Set(items.compactMap(\.groupID)).count == 1)
        for item in items {
            guard case .similarVideo(let width, let height, let duration, let codec) = item.detail else {
                Issue.record("video entry must carry similarVideo detail")
                continue
            }
            #expect(width == 320)
            #expect(height == 240)
            #expect(duration == 2.0)
            #expect(codec == "h264")
            #expect(item.sizeBytes > 0)
        }
    }

    // MARK: flat inspected tools (symlinks, broken, ext, bad-names)

    @Test("symlinks: entries carry destination and error type")
    func symlinksFixture() throws {
        let items = try parse("symlinks.json", tool: .invalidSymlinks)
        #expect(items.count == 1)
        let item = try #require(items.first)
        guard case .invalidSymlink(let destination, let error) = item.detail else {
            Issue.record("symlink entry must carry invalidSymlink detail")
            return
        }
        #expect(destination.hasSuffix("missing-target.txt"))
        #expect(error == "NonExistentFile")
        // The engine reports the symlink's own length (the target path it stores).
        #expect(item.sizeBytes == 92)
        #expect(item.groupID == nil)
    }

    @Test("broken: entries carry an errors map keyed by check type")
    func brokenFixture() throws {
        let items = try parse("broken.json", tool: .brokenFiles)
        #expect(items.count == 2)
        for item in items {
            guard case .brokenFile(let errors) = item.detail else {
                Issue.record("broken entry must carry brokenFile detail")
                continue
            }
            #expect(!errors.isEmpty)
            #expect(!errors.values.contains { $0.isEmpty })
        }
        let checks = items.flatMap { item -> [String] in
            guard case .brokenFile(let errors) = item.detail else { return [] }
            return Array(errors.keys)
        }
        #expect(checks.contains("Pdf"))
        #expect(checks.contains("Image"))
    }

    @Test("ext: entries carry current and proper extensions")
    func extFixture() throws {
        let items = try parse("ext.json", tool: .wrongExtensions)
        #expect(items.count == 1)
        let item = try #require(items.first)
        guard case .wrongExtension(let current, let proper) = item.detail else {
            Issue.record("ext entry must carry wrongExtension detail")
            return
        }
        #expect(current == "txt")
        #expect(proper == "jpg")
        #expect(item.path.hasSuffix("fake_image.txt"))
    }

    @Test("bad-names: entries carry the proposed fixed name")
    func badNamesFixture() throws {
        let items = try parse("bad-names.json", tool: .badNames)
        #expect(items.count == 1)
        let item = try #require(items.first)
        guard case .badName(let suggested) = item.detail else {
            Issue.record("bad-names entry must carry badName detail")
            return
        }
        #expect(suggested == "bad name.jpg")
        #expect(item.path.hasSuffix(" bad name .JPG"))
    }

    // MARK: failure behaviour (honest errors, never silent empty)

    @Test("garbage bytes throw unparseable")
    func garbageThrowsUnparseable() {
        let garbage = Data("this is not json at all".utf8)
        #expect(throws: CzkawkaJSONError.unparseable) {
            _ = try CzkawkaJSON.items(in: garbage, tool: .bigFiles)
        }
    }

    @Test("right shape parsed with the wrong method throws unexpectedShape")
    func wrongTopLevelShapeThrows() throws {
        // dup.json (HASH) has an object root; SIZE_NAME demands a bare array.
        let bytes = try data("dup.json")
        do {
            _ = try CzkawkaJSON.items(in: bytes, tool: .duplicates, dupSearchMethod: .sizeName)
            Issue.record("object-rooted dup JSON parsed as SIZE_NAME must throw")
        } catch let error as CzkawkaJSONError {
            guard case .unexpectedShape(let detail) = error else {
                Issue.record("wrong error kind: \(error)")
                return
            }
            #expect(detail.contains("SIZE_NAME"))
        }
    }

    @Test("wrong root type for a flat tool throws unexpectedShape")
    func wrongFlatRootThrows() throws {
        let bytes = try data("dup.json")
        do {
            _ = try CzkawkaJSON.items(in: bytes, tool: .bigFiles)
            Issue.record("object-rooted JSON parsed as big must throw")
        } catch let error as CzkawkaJSONError {
            guard case .unexpectedShape = error else {
                Issue.record("wrong error kind: \(error)")
                return
            }
        }
    }

    @Test("malformed individual entries are skipped, not fatal")
    func malformedEntriesSkipped() throws {
        // One good entry, one without a path (skipped), one without a size (kept, 0).
        let json = #"[{"path":"/keep/me","size":512},{"size":99},{"path":"/keep/zero"}]"#
        let items = try CzkawkaJSON.items(in: Data(json.utf8), tool: .bigFiles)
        #expect(items.count == 2)
        #expect(items[0].sizeBytes == 512)
        #expect(items[1].sizeBytes == 0)
    }

    @Test("forEachItem and items agree on every fixture (ignoring random item ids)")
    func forEachMatchesCollect() throws {
        for (name, tool) in [
            ("dup.json", CzkawkaTool.duplicates),
            ("empty-folders.json", CzkawkaTool.emptyFolders),
            ("big.json", CzkawkaTool.bigFiles),
            ("empty-files.json", CzkawkaTool.emptyFiles),
            ("temp.json", CzkawkaTool.temporaryFiles),
            ("image.json", CzkawkaTool.similarImages),
            ("music.json", CzkawkaTool.similarMusic),
            ("video.json", CzkawkaTool.similarVideos),
            ("symlinks.json", CzkawkaTool.invalidSymlinks),
            ("broken.json", CzkawkaTool.brokenFiles),
            ("ext.json", CzkawkaTool.wrongExtensions),
            ("bad-names.json", CzkawkaTool.badNames),
        ] {
            let bytes = try data(name)
            let streamed: [CzkawkaItem] = try {
                var out: [CzkawkaItem] = []
                try CzkawkaJSON.forEachItem(in: bytes, tool: tool) { out.append($0) }
                return out
            }()
            let collected = try CzkawkaJSON.items(in: bytes, tool: tool)
            // ids are random per parse, so compare the fields that matter.
            func key(_ item: CzkawkaItem) -> String {
                "\(item.path)|\(item.sizeBytes)|\(item.tool.clapName)|\(item.groupID ?? "-")|\(String(describing: item.detail))"
            }
            #expect(streamed.map(key) == collected.map(key), "forEachItem and items must agree for \(name)")
        }
    }

    // MARK: item model helpers

    @Test("similarity spans 0...1 over the engine's 0...40 difference range")
    func similarityBounds() {
        let identical = CzkawkaItem(
            path: "/a.jpg", sizeBytes: 1, tool: .similarImages,
            detail: .similarImage(width: 1, height: 1, difference: 0)
        )
        let worst = CzkawkaItem(
            path: "/b.jpg", sizeBytes: 1, tool: .similarImages,
            detail: .similarImage(width: 1, height: 1, difference: 40)
        )
        #expect(identical.similarity == 1.0)
        #expect(worst.similarity == 0.0)
    }

    @Test("group adjacency: entries of one group are contiguous")
    func groupAdjacency() throws {
        let items = try parse("dup.json", tool: .duplicates)
        var finished: Set<String> = []
        var current: String?
        for item in items {
            let group = item.groupID ?? ""
            if group != current {
                #expect(!finished.contains(group), "group \(group) reappears after ending")
                if let current { finished.insert(current) }
                current = group
            }
        }
    }

    @Test("tool enum clap names match the verified subcommand list")
    func clapNames() {
        #expect(CzkawkaTool.allCases.map(\.clapName)
            == ["dup", "empty-folders", "big", "empty-files", "temp", "image", "music", "video",
                "symlinks", "broken", "ext", "bad-names"])
        #expect(CzkawkaDupSearchMethod.allCases.map(\.clapValue)
            == ["HASH", "SIZE", "NAME", "SIZE_NAME"])
        // bad-names checks are opt-in; every check flag is enabled by default.
        #expect(CzkawkaTool.badNames.extraClapFlags == ["-u", "-j", "-w", "-n", "-a"])
        // No tool ever enables in-place fixing or deletion.
        #expect(CzkawkaTool.allCases.allSatisfy { !$0.extraClapFlags.contains("-F") })
    }
}

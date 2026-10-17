import Foundation
import Testing
@testable import Tebo

// MARK: - DeletePipeline tests
// The delete path is the highest-risk code in the app: these tests prove
// every refusal branch deletes NOTHING, and the happy path deletes only the
// exact file it validated. Everything runs in temp dirs and cleans up.

@Suite("DeletePipeline")
struct DeletePipelineTests {

    /// Fresh temp dir per test, removed on exit.
    private func makeDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-del-\(UUID().uuidString)", isDirectory: true)
    }

    /// Where trashItem lands a same-volume file: ~/.Trash/<name>. Used only
    /// to clean up our OWN unique test artifacts out of the real Trash.
    private func trashedLocation(of url: URL) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/\(url.lastPathComponent)")
    }

    @Test("Gate-rejected path is skipped and the file survives")
    func gateRejectedSkipped() async throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("keepme.txt")
        try Data("precious".utf8).write(to: file)

        // "keepme.txt" in the whitelist makes the gate reject the path.
        let report = await DeletePipeline().trash(paths: [file.path], whitelist: ["keepme.txt"])

        #expect(report.outcomes.count == 1)
        #expect(report.outcomes[0].result == .skipped(reason: .invalidPath(.whitelisted)))
        #expect(report.skippedCount == 1)
        #expect(report.trashedCount == 0)
        #expect(report.freedBytes == 0)
        // The real assertion: the file still exists, untouched.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == "precious")
    }

    @Test("Critical system path is refused before anything touches disk")
    func criticalPathRefused() async {
        // A nonexistent path under /System: the string rules reject it in
        // step 1, before any stat or move. Nothing here is a real file.
        let report = await DeletePipeline().trash(
            paths: ["/System/tebo-nonexistent-xyz"], whitelist: []
        )
        #expect(
            report.outcomes[0].result == .skipped(reason: .invalidPath(.criticalSystemPath))
        )
        #expect(report.freedBytes == 0)
    }

    @Test("Identity change between validation and the move is skipped")
    func identityMismatchSkipped() async throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("swap.txt")
        try Data("original".utf8).write(to: file)

        // Simulate a rename-and-recreate race: the hook swaps the file after
        // validation but before the final identity check.
        let report = await DeletePipeline().trash(
            paths: [file.path],
            whitelist: [],
            beforeMove: { path in
                try? FileManager.default.removeItem(atPath: path)
                try? Data("replacement".utf8).write(to: URL(fileURLWithPath: path))
            }
        )

        #expect(report.outcomes.count == 1)
        #expect(report.outcomes[0].result == .skipped(reason: .identityChanged))
        #expect(report.freedBytes == 0)
        // The replacement survives: nothing we did not validate got trashed.
        #expect(FileManager.default.fileExists(atPath: file.path))
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content == "replacement")
    }

    @Test("Missing path is skipped, never crashes")
    func missingSkipped() async {
        let missing = makeDir().appendingPathComponent("gone.txt").path
        let report = await DeletePipeline().trash(paths: [missing], whitelist: [])
        #expect(report.outcomes.count == 1)
        #expect(report.outcomes[0].result == .skipped(reason: .missing))
        #expect(report.freedBytes == 0)
    }

    @Test("Normal file is moved to Trash and the report says so")
    func normalFileTrashed() async throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("bye-\(UUID().uuidString).txt")
        let data = Data(repeating: 0x42, count: 512)
        try data.write(to: file)
        // Unique name, so the Trash cleanup cannot touch a real user file.
        defer { try? FileManager.default.removeItem(at: trashedLocation(of: file)) }

        let report = await DeletePipeline().trash(paths: [file.path], whitelist: [])

        #expect(report.outcomes.count == 1)
        #expect(report.outcomes[0].result == .trashed(bytes: 512))
        #expect(report.trashedCount == 1)
        #expect(report.skippedCount == 0)
        #expect(report.failedCount == 0)
        #expect(report.freedBytes == 512)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Batch mixes outcomes and reports each path exactly once")
    func mixedBatch() async throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = dir.appendingPathComponent("good-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: good)
        defer { try? FileManager.default.removeItem(at: trashedLocation(of: good)) }
        let whitelisted = dir.appendingPathComponent("wl.txt")
        try Data("y".utf8).write(to: whitelisted)

        let report = await DeletePipeline().trash(
            paths: [good.path, whitelisted.path, dir.appendingPathComponent("gone.txt").path],
            whitelist: ["wl.txt"]
        )

        #expect(report.outcomes.count == 3)
        #expect(report.trashedCount == 1)
        #expect(report.skippedCount == 2)
        #expect(report.failedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: good.path))
        #expect(FileManager.default.fileExists(atPath: whitelisted.path))
    }

    @Test("The cleanup sink's own measurement keeps an escaping link and passes a contained one")
    func cleanupSinkRevalidatesWithContract() async throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Unique leaf so the Trash cleanup below cannot touch a real user item.
        let item = dir.appendingPathComponent("cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: item.appendingPathComponent("data.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: item.appendingPathComponent("escape").path,
            withDestinationPath: dir.appendingPathComponent("outside.bin").path)

        // The nil-returning validator isolates the sink's own measurement:
        // only cleanupSize and the open-handle probe stand in front of the move.
        func trash(_ path: String) async -> DeleteReport {
            await DeletePipeline().trash(
                paths: [path], whitelist: [],
                expectedIdentities: [path: FileIdentity.read(path: path)].compactMapValues { $0 },
                expectedBindings: [path: PathBinding.read(path: path)].compactMapValues { $0 },
                requirePreviewIdentity: true, enforceCleanupSafety: true,
                additionalValidation: { _ in nil },
                ruleContract: { _ in
                    MoleRuleContract(budget: .bulk, evidencePolicy: .developerCache, containmentRoot: item.path)
                })
        }

        let escaping = await trash(item.path)
        #expect(escaping.skippedCount == 1)
        #expect(FileManager.default.fileExists(atPath: item.path))

        // A link that stays inside the contract's root is tolerated, and the
        // item then moves exactly once.
        try FileManager.default.removeItem(at: item.appendingPathComponent("escape"))
        try FileManager.default.createSymbolicLink(
            atPath: item.appendingPathComponent("contained").path, withDestinationPath: "data.bin")
        defer { try? FileManager.default.removeItem(at: trashedLocation(of: item)) }
        let contained = await trash(item.path)
        #expect(contained.trashedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: item.path))
    }
}

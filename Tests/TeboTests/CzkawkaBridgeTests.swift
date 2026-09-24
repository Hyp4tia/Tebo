import Darwin
import Foundation
import Testing
@testable import Tebo

// MARK: - CzkawkaBridge tests
// The bridge's contract, proven two ways:
//   * against a fake engine (bash script) for every failure mode, cancellation and
//     argv hygiene, with no dependency on the real 27 MB binary;
//   * against the REAL Engines/czkawka_cli when this checkout has it (hash-verified),
//     proving the live path: temp-file JSON, no deletion, no orphan, no leaks.
// The suite is serialized: the tests count processes and temp dirs.

@Suite("CzkawkaBridge", .serialized)
struct CzkawkaBridgeTests {

    // MARK: Engine discovery (repo checkout fallback, like EngineLocator)

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TeboTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static let realEngineURL = repoRoot.appendingPathComponent("Engines/czkawka_cli")

    private static let engineAvailable = FileManager.default.isExecutableFile(atPath: realEngineURL.path)

    // MARK: Helpers

    /// Temp dirs the bridge creates during a scan. Empty after every clean run.
    private func tempScanDirs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix("tebo-scan-") } ?? []
    }

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes an executable bash fake engine whose behaviour is baked in (no env vars,
    /// no cross-test coupling). When `payload` is set it writes that JSON to the `-p`
    /// target, exactly like the real engine does.
    private func makeFakeEngine(
        payload: String? = nil,
        exitCode: Int = 0,
        stderr: String = "",
        sleepSeconds: Int = 0,
        argsFile: URL? = nil,
        pidFile: URL? = nil
    ) throws -> URL {
        let dir = try makeTempDir("tebo-fake")
        let script = dir.appendingPathComponent("engine.sh")
        func q(_ string: String) -> String {
            string.replacingOccurrences(of: "'", with: "'\\''")
        }
        var lines = ["#!/bin/bash", "set -u"]
        if let argsFile {
            lines.append("printf '%s\\n' \"$@\" > '\(q(argsFile.path))'")
        }
        if let pidFile {
            lines.append("echo \"$$\" > '\(q(pidFile.path))'")
        }
        if !stderr.isEmpty {
            lines.append("printf '%s' '\(q(stderr))' >&2")
        }
        if let payload {
            lines.append("""
            json=""; prev=""
            for a in "$@"; do
              if [ "$prev" = "-p" ]; then json="$a"; break; fi
              prev="$a"
            done
            [ -n "$json" ] && printf '%s' '\(q(payload))' > "$json"
            """)
        }
        if sleepSeconds > 0 {
            // exec replaces the script with sleep: the recorded pid IS the sleeper,
            // so SIGTERM from the bridge kills exactly that process (no orphan child).
            lines.append("exec sleep \(sleepSeconds)")
        }
        lines.append("exit \(exitCode)")
        try lines.joined(separator: "\n").appending("\n")
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func dupPayload(for dir: URL) -> String {
        """
        {"12345": [[{"path": "\(dir.path)/a.bin", "modified_date": 1790000000, "size": 12345, "hash": "0b2eadda2b1900fd11afeef6c368a5635d58ef5c0c2af09f4d3a6a74c0b2d167"}, {"path": "\(dir.path)/b.bin", "modified_date": 1790000001, "size": 12345, "hash": "0b2eadda2b1900fd11afeef6c368a5635d58ef5c0c2af09f4d3a6a74c0b2d167"}]]}
        """
    }

    private func pidIsAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0
    }

    /// Counts running `czkawka_cli` processes via sysctl — no child process, so it
    /// cannot wedge on /bin/ps (which hangs under heavy process churn).
    private func czkawkaProcessCount() -> Int {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return 0 }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        let count = size / MemoryLayout<kinfo_proc>.stride
        let result = processes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return 0 }
        var matches = 0
        for index in 0..<count {
            var comm = processes[index].kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "czkawka_cli" { matches += 1 }
        }
        return matches
    }

    // MARK: Failure modes (honest, typed errors)

    @Test("missing engine throws engineMissing")
    func missingEngineThrows() async throws {
        let nowhereDir = try makeTempDir("tebo-absent")
        defer { try? FileManager.default.removeItem(at: nowhereDir) }
        let nowhere = nowhereDir.appendingPathComponent("no-such-engine")
        let bridge = CzkawkaBridge(engineURL: nowhere)
        let tree = try makeTempDir("tebo-tree")
        defer { try? FileManager.default.removeItem(at: tree) }
        do {
            _ = try await bridge.results(tool: .duplicates, in: [tree])
            Issue.record("missing engine must throw")
        } catch let error as CzkawkaBridgeError {
            #expect(error == .engineMissing)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(tempScanDirs().isEmpty)
    }

    @Test("happy path: items decoded from the -p file, temp dir removed")
    func happyPathYieldsItemsAndCleansTemp() async throws {
        let tree = try makeTempDir("tebo-tree")
        let payloadDir = try makeTempDir("tebo-payload")
        let engine = try makeFakeEngine(payload: dupPayload(for: payloadDir))
        let items = try await CzkawkaBridge(engineURL: engine).results(tool: .duplicates, in: [tree])

        #expect(items.count == 2)
        #expect(items.map(\.path).sorted() == ["\(payloadDir.path)/a.bin", "\(payloadDir.path)/b.bin"].sorted())
        #expect(items.allSatisfy { $0.sizeBytes == 12345 })
        #expect(items[0].groupID == "hash:0b2eadda2b1900fd11afeef6c368a5635d58ef5c0c2af09f4d3a6a74c0b2d167")
        #expect(tempScanDirs().isEmpty)   // the per-scan JSON dir is gone
        try? FileManager.default.removeItem(at: tree)
        try? FileManager.default.removeItem(at: payloadDir)
    }

    @Test("exit code 11 is items found, not an error")
    func exitElevenIsSuccess() async throws {
        let tree = try makeTempDir("tebo-tree")
        let payloadDir = try makeTempDir("tebo-payload")
        // Without -W the engine exits 11 when it finds items; the bridge always passes
        // -W, but must still treat 11 as success if the flag were ever ignored.
        let engine = try makeFakeEngine(payload: dupPayload(for: payloadDir), exitCode: 11)
        let items = try await CzkawkaBridge(engineURL: engine).results(tool: .duplicates, in: [tree])
        #expect(items.count == 2)
        #expect(tempScanDirs().isEmpty)
        try? FileManager.default.removeItem(at: tree)
        try? FileManager.default.removeItem(at: payloadDir)
    }

    @Test("non-zero exit throws engineFailed carrying the stderr tail")
    func nonZeroExitSurfacesStderr() async throws {
        let tree = try makeTempDir("tebo-tree")
        defer { try? FileManager.default.removeItem(at: tree) }
        let engine = try makeFakeEngine(exitCode: 2, stderr: "line one\nFATAL-SENTINEL: boom\nline three\n")
        do {
            _ = try await CzkawkaBridge(engineURL: engine).results(tool: .duplicates, in: [tree])
            Issue.record("exit 2 must throw")
        } catch let error as CzkawkaBridgeError {
            guard case .engineFailed(let code, let tail) = error else {
                Issue.record("wrong error kind: \(error)")
                return
            }
            #expect(code == 2)
            #expect(tail.contains("FATAL-SENTINEL: boom"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(tempScanDirs().isEmpty)
    }

    @Test("engine that wrote no JSON throws unparseableJSON, not empty results")
    func missingJSONFileThrows() async throws {
        let tree = try makeTempDir("tebo-tree")
        defer { try? FileManager.default.removeItem(at: tree) }
        let engine = try makeFakeEngine(payload: nil, exitCode: 0)   // never touches -p
        do {
            _ = try await CzkawkaBridge(engineURL: engine).results(tool: .duplicates, in: [tree])
            Issue.record("missing JSON must throw")
        } catch let error as CzkawkaBridgeError {
            guard case .unparseableJSON(let detail) = error else {
                Issue.record("wrong error kind: \(error)")
                return
            }
            #expect(detail.contains("no JSON"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(tempScanDirs().isEmpty)
    }

    @Test("invalid JSON in the -p file throws unparseableJSON")
    func invalidJSONThrows() async throws {
        let tree = try makeTempDir("tebo-tree")
        defer { try? FileManager.default.removeItem(at: tree) }
        let engine = try makeFakeEngine(payload: "{not json at all", exitCode: 0)
        do {
            _ = try await CzkawkaBridge(engineURL: engine).results(tool: .duplicates, in: [tree])
            Issue.record("invalid JSON must throw")
        } catch let error as CzkawkaBridgeError {
            guard case .unparseableJSON = error else {
                Issue.record("wrong error kind: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(tempScanDirs().isEmpty)
    }

    // MARK: argv hygiene (requirement: -N -M -W, never -D or -y)

    @Test("engine argv is complete and never destructive")
    func argumentsAreSafeAndComplete() async throws {
        let tree = try makeTempDir("tebo-tree")
        let payloadDir = try makeTempDir("tebo-payload")
        let argsFile = try makeTempDir("tebo-args").appendingPathComponent("args.txt")
        let engine = try makeFakeEngine(payload: dupPayload(for: payloadDir), argsFile: argsFile)

        _ = try await CzkawkaBridge(engineURL: engine)
            .results(tool: .duplicates, in: [tree], dupSearchMethod: .hash)

        let args = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(args.first == "dup")
        #expect(args.contains("-N") && args.contains("-M") && args.contains("-W"))
        #expect(args.contains("-p"))
        #expect(args.contains("-s") && args.contains("HASH"))
        // Exactly one -d pair pointing at the requested tree.
        let dIndices = args.indices.filter { args[$0] == "-d" }
        #expect(dIndices.count == 1)
        #expect(dIndices.allSatisfy { args[$0 + 1] == tree.path })
        // The scan must never be destructive or self-fixing.
        for banned in ["-D", "--delete-method", "-y", "--move-to-trash", "-Q", "--dry-run",
                       "--delete-files", "-F", "--fix-names"] {
            #expect(!args.contains(banned), "engine argv must never contain \(banned)")
        }
        // The JSON file the bridge passed existed during the run and is gone now.
        if let jsonIndex = args.firstIndex(of: "-p") {
            let jsonPath = args[jsonIndex + 1]
            #expect(!FileManager.default.fileExists(atPath: jsonPath))
        } else {
            Issue.record("-p argument missing")
        }
        #expect(tempScanDirs().isEmpty)
        try? FileManager.default.removeItem(at: tree)
        try? FileManager.default.removeItem(at: payloadDir)
    }

    @Test("every tool maps to its exact clap subcommand, dup adds -s only")
    func toolNamesPassedVerbatim() async throws {
        let tree = try makeTempDir("tebo-tree")
        defer { try? FileManager.default.removeItem(at: tree) }
        // One fake engine per tool: each records the argv it was spawned with.
        for tool in CzkawkaTool.allCases {
            let argsDir = try makeTempDir("tebo-args")
            defer { try? FileManager.default.removeItem(at: argsDir) }
            let argsFile = argsDir.appendingPathComponent("args.txt")
            let engine = try makeFakeEngine(payload: "[]", argsFile: argsFile)
            _ = try await CzkawkaBridge(engineURL: engine)
                .results(tool: tool, in: [tree], dupSearchMethod: .sizeName)
            let args = try String(contentsOf: argsFile, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            #expect(args.first == tool.clapName, "subcommand must be the exact clap name")
            if tool == .duplicates {
                #expect(args.contains("-s") && args.contains("SIZE_NAME"))
            } else {
                #expect(!args.contains("-s"), "\(tool.clapName) must not get a dup search method")
            }
            // bad-names checks are opt-in: without any of these the engine returns [].
            if tool == .badNames {
                for flag in ["-u", "-j", "-w", "-n", "-a"] {
                    #expect(args.contains(flag), "bad-names must enable check \(flag)")
                }
            }
            // Fix flags rewrite files in place; Tebo must never pass them.
            #expect(!args.contains("-F"), "\(tool.clapName) must never get the -F fix flag")
        }
        #expect(tempScanDirs().isEmpty)
    }

    // MARK: cancellation

    @Test("cancelling the consumer kills the engine process and cleans temp files")
    func cancellationKillsEngineAndCleansTemp() async throws {
        let tree = try makeTempDir("tebo-tree")
        let pidFile = try makeTempDir("tebo-pid").appendingPathComponent("engine.pid")
        let engine = try makeFakeEngine(sleepSeconds: 60, pidFile: pidFile)
        let bridge = CzkawkaBridge(engineURL: engine)

        let consumer = Task {
            var items: [CzkawkaItem] = []
            for try await item in bridge.scan(tool: .duplicates, in: [tree]) {
                items.append(item)
            }
            return items
        }
        // Give the engine time to spawn, write its pid and start sleeping.
        try await Task.sleep(for: .milliseconds(400))
        consumer.cancel()
        _ = await consumer.result   // must return promptly, not hang

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int(pidText) else {
            Issue.record("fake engine never wrote its pid")
            return
        }
        // The child must actually die, not linger as an orphan.
        let deadline = Date().addingTimeInterval(5)
        var alive = pidIsAlive(pid)
        while alive && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            alive = pidIsAlive(pid)
        }
        #expect(!alive, "engine process \(pid) survived cancellation")
        #expect(tempScanDirs().isEmpty)
        try? FileManager.default.removeItem(at: tree)
    }

    // MARK: real engine (skipped when the checkout has no Engines/czkawka_cli)

    @Test("real engine: dup finds a planted pair and deletes nothing", .enabled(if: engineAvailable))
    func realEngineEndToEnd() async throws {
        let tree = try makeTempDir("tebo-real")
        defer { try? FileManager.default.removeItem(at: tree) }
        let a = tree.appendingPathComponent("a.bin")
        let b = tree.appendingPathComponent("sub/b.bin")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        let duplicate = Data(repeating: 0xAB, count: 16_384)
        try duplicate.write(to: a)
        try duplicate.write(to: b)
        // Same size, different content: must NOT be grouped with the pair.
        try Data(repeating: 0xCD, count: 16_384).write(to: tree.appendingPathComponent("c.bin"))

        let items = try await CzkawkaBridge(engineURL: Self.realEngineURL)
            .results(tool: .duplicates, in: [tree])

        let pair = items.filter { $0.path.hasSuffix("a.bin") || $0.path.hasSuffix("b.bin") }
        try #require(pair.count == 2, "expected the planted pair, got \(pair.map { $0.path })")
        #expect(pair[0].groupID == pair[1].groupID)
        #expect(!items.contains { $0.path.hasSuffix("c.bin") })
        // Scanning must never delete: every planted file is still on disk.
        for url in [a, b, tree.appendingPathComponent("c.bin")] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(tempScanDirs().isEmpty)
    }

    @Test("real engine: cancelling mid-scan leaves no orphan and no temp files", .enabled(if: engineAvailable))
    func realEngineCancellationLeavesNoOrphan() async throws {
        let before = czkawkaProcessCount()
        let tree = try makeTempDir("tebo-real-cancel")
        defer { try? FileManager.default.removeItem(at: tree) }
        // Enough hashing work that the scan cannot finish before we cancel.
        let blob = Data(repeating: 0x5A, count: 12_288)
        for index in 0..<600 {
            try blob.write(to: tree.appendingPathComponent("f\(index).bin"))
        }

        let bridge = CzkawkaBridge(engineURL: Self.realEngineURL)
        let consumer = Task {
            var items: [CzkawkaItem] = []
            for try await item in bridge.scan(tool: .duplicates, in: [tree]) {
                items.append(item)
            }
            return items
        }
        try await Task.sleep(for: .milliseconds(150))
        consumer.cancel()
        _ = await consumer.result   // must return, not hang

        // Any czkawka_cli the scan spawned must be gone again.
        let deadline = Date().addingTimeInterval(5)
        var count = czkawkaProcessCount()
        while count > before && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            count = czkawkaProcessCount()
        }
        #expect(count <= before, "czkawka_cli process orphaned after cancellation")
        #expect(tempScanDirs().isEmpty)
    }
}

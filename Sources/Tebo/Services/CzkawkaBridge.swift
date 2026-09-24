import Foundation

// MARK: - CzkawkaBridge
// Correct, cancellable wrapper around the bundled Rust engine `czkawka_cli`
// (qarmin/czkawka 12.0.2, MIT, hash-verified by EngineLocator).
//
// HOW A SCAN RUNS (all facts verified against the real binary, see
// Tests/Fixtures/czkawka/README.md):
//   1. czkawka_cli writes its results as ONE JSON document to the file named by
//      `-p` (pretty-file-to-save). It NEVER writes JSON to stdout.
//   2. We always pass `-N -M` (silence results + messages on stdout) and `-W`
//      (exit 0 instead of 11 when items are found). We NEVER pass `-D` or `-y`:
//      scanning must never delete.
//   3. stdout is drained and discarded; stderr is captured (tail) so failures carry
//      the engine's own words.
//   4. The JSON file is parsed via Services/CzkawkaJSON and each item is yielded one
//      at a time, so a shared ScanTab can render lazily without a full array in memory.
//   5. Cancelling the consumer task terminates the child process (no orphan engine),
//      and the per-scan temp directory (JSON + engine cache/config) is deleted either
//      way (no leaked temp files).
//   6. Exit code 0 = success, 11 = "items found" (not an error; -W normally forces 0
//      anyway, this is defensive). Anything else = .engineFailed with the stderr tail.

/// Typed bridge failure. Never silent: a failed scan raises, it never yields an
/// empty stream and pretends everything was fine.
public enum CzkawkaBridgeError: Error, Equatable, Sendable, LocalizedError {
    /// The engine binary does not exist or is not executable at `engineURL`.
    case engineMissing
    /// The engine ran but exited non-zero. `stderrTail` is the last part of its stderr.
    case engineFailed(exitCode: Int32, stderrTail: String)
    /// The engine ran (or not) but its JSON could not be read or parsed. `detail` says why.
    case unparseableJSON(detail: String)
    /// The scan was cancelled; the engine process was terminated.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .engineMissing: "czkawka engine is missing or not executable"
        case .engineFailed(let code, let tail):
            "czkawka engine exited \(code): \(tail.isEmpty ? "(empty stderr)" : tail)"
        case .unparseableJSON(let detail): "czkawka output unusable: \(detail)"
        case .cancelled: "scan cancelled"
        }
    }
}

/// Thin, Sendable wrapper around the `czkawka_cli` binary.
public struct CzkawkaBridge: Sendable {

    /// Path to the engine binary (the hash-verified Engines/czkawka_cli, or the
    /// bundled/signed copy inside the app).
    public let engineURL: URL

    public init(engineURL: URL) {
        self.engineURL = engineURL
    }

    // MARK: Public API

    /// Scan with one czkawka tool and stream findings as they are parsed.
    ///
    /// - Parameters:
    ///   - tool: Which engine tool to run (its `clapName` becomes the subcommand).
    ///   - directories: Roots to scan (each becomes one `-d` argument).
    ///   - dupSearchMethod: Only used when `tool == .duplicates`; forwarded as `-s`.
    /// - Returns: An `AsyncThrowingStream<CzkawkaItem, Error>` that yields items in
    ///   engine order and finishes by throwing a `CzkawkaBridgeError` on failure.
    /// - Cancellation: cancelling the consumer task of this stream terminates the
    ///   engine process and cleans up the scan's temp files; iteration ends with
    ///   `CzkawkaBridgeError.cancelled` when the scan task itself was cancelled.
    public func scan(
        tool: CzkawkaTool,
        in directories: [URL],
        dupSearchMethod: CzkawkaDupSearchMethod = .hash
    ) -> AsyncThrowingStream<CzkawkaItem, Error> {
        precondition(!directories.isEmpty, "scan requires at least one directory")
        let engineURL = self.engineURL
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await Self.run(
                        engineURL: engineURL,
                        tool: tool,
                        directories: directories,
                        dupSearchMethod: dupSearchMethod
                    ) { item in
                        try Task.checkCancellation()
                        continuation.yield(item)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CzkawkaBridgeError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Convenience for callers that want a plain array (small scans, tests).
    /// Same contract and errors as `scan`; honours Task cancellation identically.
    public func results(
        tool: CzkawkaTool,
        in directories: [URL],
        dupSearchMethod: CzkawkaDupSearchMethod = .hash
    ) async throws -> [CzkawkaItem] {
        var collected: [CzkawkaItem] = []
        for try await item in scan(tool: tool, in: directories, dupSearchMethod: dupSearchMethod) {
            collected.append(item)
        }
        return collected
    }

    // MARK: Engine execution

    /// Runs the engine synchronously (inside the caller's detached task), yielding
    /// parsed items via `yield`. Throws `CzkawkaBridgeError` / `CzkawkaJSONError` /
    /// `CancellationError`.
    private static func run(
        engineURL: URL,
        tool: CzkawkaTool,
        directories: [URL],
        dupSearchMethod: CzkawkaDupSearchMethod,
        yield: (CzkawkaItem) throws -> Void
    ) async throws {
        // Fail fast and loud: a missing engine is an error, never an empty scan.
        guard FileManager.default.isExecutableFile(atPath: engineURL.path) else {
            throw CzkawkaBridgeError.engineMissing
        }

        // One fresh temp dir per scan: JSON output + redirected engine cache/config.
        // Everything under it is removed afterwards, so the bridge cannot leak files.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonURL = tempDir.appendingPathComponent("results.json", isDirectory: false)

        var arguments = [tool.clapName]
        for directory in directories {
            arguments.append(contentsOf: ["-d", directory.path])
        }
        if tool == .duplicates {
            arguments.append(contentsOf: ["-s", dupSearchMethod.clapValue])
        }
        // Per-tool opt-in flags (bad-names checks). Never -F (fix rewrites files in
        // place), never -D/-y (delete/trash): Tebo only finds, it never mutates.
        arguments.append(contentsOf: tool.extraClapFlags)
        arguments.append(contentsOf: ["-p", jsonURL.path, "-N", "-M", "-W"])
        // Safety rule (never violated, and covered by a test): no -D, no -y, no other
        // delete/trash flags. The engine only finds; DeletePipeline alone may trash.

        // Keep the engine's own cache/config inside the per-scan temp dir: isolates runs, keeps the
        // user's home clean, and guarantees removal with the temp dir.
        var environment = ProcessInfo.processInfo.environment
        environment["CZKAWKA_CACHE_PATH"] = tempDir.appendingPathComponent("cache").path
        environment["CZKAWKA_CONFIG_PATH"] = tempDir.appendingPathComponent("config").path

        // Exit comes from the shared runner's terminationHandler. Not waitUntilExit(): after a
        // cancel-triggered terminate() the blocking wait can miss the child's exit event and hang
        // the scan forever (observed on this machine). No deadline here: scanning a large tree
        // legitimately takes minutes and the user can cancel at any point.
        let result = await BoundedProcessRunner.run(
            executablePath: engineURL.path,
            arguments: arguments,
            timeout: nil,
            environment: environment
        )

        try Task.checkCancellation()

        guard let exitCode = result.terminationStatus else {
            throw CzkawkaBridgeError.engineFailed(exitCode: -1, stderrTail: result.stderr)
        }
        // 0 = success, 11 = items found (not an error; -W normally forces 0 anyway).
        guard exitCode == 0 || exitCode == 11 else {
            throw CzkawkaBridgeError.engineFailed(exitCode: exitCode, stderrTail: result.stderr)
        }

        // The engine writes ONE JSON document to -p. Missing file = engine lied or
        // crashed; that is a hard error, not an empty result.
        guard let data = try? Data(contentsOf: jsonURL) else {
            throw CzkawkaBridgeError.unparseableJSON(
                detail: "engine exited \(exitCode) but wrote no JSON to \(jsonURL.lastPathComponent)"
            )
        }

        do {
            try CzkawkaJSON.forEachItem(in: data, tool: tool, dupSearchMethod: dupSearchMethod) { item in
                try yield(item)
            }
        } catch let error as CzkawkaJSONError {
            throw CzkawkaBridgeError.unparseableJSON(detail: String(describing: error))
        }
    }
}


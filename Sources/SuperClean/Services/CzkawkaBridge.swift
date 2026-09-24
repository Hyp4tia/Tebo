import Foundation

// MARK: - CzkawkaBridge
// Talks to the bundled Rust binary `czkawka_cli` (from qarmin/czkawka, GPL-3.0).
// Swift never reimplements hashing — it just runs the CLI and parses JSON.
// Efficient: streams NDJSON line-by-line, never loads whole output in RAM.

/// Thin wrapper around the `czkawka_cli` helper binary.
/// - M1: returns mock data (no binary needed to run the UI shell).
/// - M3: set `engineURL` to the bundled binary to go live.
public struct CzkawkaBridge: Sendable {

    /// Path to `czkawka_cli` inside SuperClean.app/Contents/MacOS/.
    /// `nil` in M1 = UI runs with mock data.
    public var engineURL: URL?

    public init(engineURL: URL? = nil) {
        self.engineURL = engineURL
    }

    // MARK: Live scan (M3)

    /// Run e.g. `czkawka_cli dup -d /Users/me --json` and stream results.
    /// Each JSON line = one ScanResult. Cancellation = Task.cancel().
    public func scanDuplicates(in directory: String) -> AsyncStream<ScanResult> {
        AsyncStream { continuation in
            guard let binary = engineURL else {
                // No engine bundled yet → caller falls back to mock data.
                continuation.finish()
                return
            }
            Task.detached {
                let process = Process()
                process.executableURL = binary
                // Keep args minimal and explicit. Add more flags in M3.
                process.arguments = ["dup", "-d", directory, "--json"]
                let pipe = Pipe()
                process.standardOutput = pipe
                do {
                    try process.run()
                    // Read line-by-line (memory-efficient for 100k files).
                    for try await line in pipe.fileHandleForReading.bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let decoded = try? JSONDecoder().decode(ScanResult.self, from: data)
                        else { continue }
                        continuation.yield(decoded)
                    }
                } catch {
                    // Fail closed: log, yield nothing. UI shows empty state.
                    await OperationLog.shared.record("Engine error: \(error.localizedDescription)")
                }
                continuation.finish()
            }
        }
    }

    // MARK: Live scan
    // Results arrive as one JSON document written to a temp file (see CzkawkaProcess), never on
    // stdout: czkawka_cli has no stdout JSON mode. The parsers live in Services/CzkawkaJSON.
}

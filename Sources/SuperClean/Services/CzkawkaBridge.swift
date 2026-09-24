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

    // MARK: Mock data (M1 UI shell)

    /// Fake results so all 6 tabs work without the Rust binary.
    /// Delete this when live engines land.
    public static func mockResults(for tab: String) -> [ScanResult] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch tab {
        case "clean":
            return [
                ScanResult(path: "\(home)/Library/Caches/Chrome", sizeBytes: 1_200_000_000, category: "User app cache", reason: "Rebuildable cache"),
                ScanResult(path: "\(home)/Library/Logs", sizeBytes: 12_800_000, category: "User app logs", reason: "Rotating logs")
            ]
        case "duplicates":
            return [
                ScanResult(path: "\(home)/Downloads/photo-copy.jpg", sizeBytes: 4_200_000, category: "Duplicates", reason: "Same hash as original"),
                ScanResult(path: "\(home)/Pictures/IMG_01-dupe.png", sizeBytes: 8_600_000, category: "Duplicates", reason: "Same hash as original")
            ]
        case "disk":
            return [
                ScanResult(path: "\(home)/Downloads/old-backup.zip", sizeBytes: 8_796_093_022, category: "Big Files", reason: "Largest files on disk")
            ]
        default:
            return [
                ScanResult(path: "\(home)/Library/Caches/example.tmp", sizeBytes: 48_000_000, category: tab.capitalized, reason: "Preview only — dry-run")
            ]
        }
    }
}

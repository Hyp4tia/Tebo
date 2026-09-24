import CryptoKit
import Foundation

// MARK: - EngineLocator
// Finds and verifies the external binaries SuperClean shells out to.
//
// WHY the hash check: the Rust engine is a 27 MB downloaded executable that decides which of the
// user's files get offered for deletion. A swapped or corrupted binary is the one failure mode we
// cannot detect any other way, so we refuse to run anything that does not match the pinned digest.

/// What we know about the bundled czkawka_cli engine.
enum EngineStatus: Sendable, Equatable {
    /// No binary anywhere we look.
    case missing
    /// Found, but not trusted (wrong hash / not executable) — carries the reason for the UI.
    case unverified(reason: String)
    /// Found and hash-verified. `version` is the pinned release the digest belongs to.
    case ready(url: URL, version: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Short user-facing description, used by Settings and the self-test.
    var summary: String {
        switch self {
        case .missing:
            return "Not installed — run scripts/fetch-engine.sh"
        case .unverified(let reason):
            return "Refused: \(reason)"
        case .ready(_, let version):
            return "\(version) — verified"
        }
    }
}

/// Locates the czkawka engine and ffmpeg, and verifies the engine against the pinned digest.
enum EngineLocator {

    /// Release + digest pinned in Engines/README.md. Bump both together.
    static let pinnedVersion = "czkawka_cli 12.0.2"
    static let pinnedSHA256 = "3362df5776b209b6365482768bc960e5a853f1b554787954c4a4c64e90bc2c75"

    /// Executable name inside Contents/Helpers of the app bundle.
    static let engineName = "czkawka_cli"

    // MARK: Locations

    /// Search order: explicit override, app bundle, developer checkout.
    /// The checkout fallback is what makes `swift run` and the test suite work without bundling.
    static func candidateURLs(fileManager: FileManager = .default) -> [URL] {
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SUPERCLEAN_ENGINE"], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override))
        }
        if let bundled = Bundle.main.url(forResource: engineName, withExtension: nil, subdirectory: "Helpers") {
            urls.append(bundled)
        }
        // Developer path: <repo>/Engines/czkawka_cli, found by walking up from the executable.
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "")
            .resolvingSymlinksInPath()
        var dir = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Engines/\(engineName)")
            urls.append(candidate)
            dir = dir.deletingLastPathComponent()
        }
        return urls
    }

    /// Full check: exists, executable, digest matches. Cheap enough to run once per launch.
    /// `candidates`/`expectedDigest` are injectable so the rules stay testable without the real binary.
    static func locate(
        candidates: [URL]? = nil,
        expectedDigest: String = pinnedSHA256,
        fileManager: FileManager = .default
    ) -> EngineStatus {
        for url in candidates ?? candidateURLs(fileManager: fileManager) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard fileManager.isExecutableFile(atPath: url.path) else {
                return .unverified(reason: "not executable: \(url.path)")
            }
            do {
                let digest = try sha256(ofFileAt: url)
                guard digest == expectedDigest else {
                    return .unverified(reason: "hash mismatch (got \(digest.prefix(12))…)")
                }
                return .ready(url: url, version: pinnedVersion)
            } catch {
                return .unverified(reason: error.localizedDescription)
            }
        }
        return .missing
    }

    /// Streaming SHA-256 so a 27 MB (or larger) binary never lands in memory in one piece.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: ffmpeg

    /// ffmpeg is optional: only the similar-videos tool and video file checks need it.
    /// We look where a GUI app actually can find it (GUI apps inherit a bare PATH).
    static func findFFmpeg(fileManager: FileManager = .default) -> String? {
        if let override = ProcessInfo.processInfo.environment["SUPERCLEAN_FFMPEG"], !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        let known = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return known.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

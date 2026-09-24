import CryptoKit
import Foundation
import Security

// MARK: - EngineLocator
// Finds and verifies the external binaries SuperClean shells out to.
//
// WHY two different integrity checks: the Rust engine is a 27 MB downloaded executable that decides
// which of the user's files get offered for deletion, so a swapped binary would be serious.
//   * Loose copy (developer checkout, Engines/czkawka_cli): compared against the pinned upstream
//     SHA-256. Strong: any modification is caught.
//   * Bundled copy: the build signs it with the app's identity, which changes its bytes, so the
//     upstream digest no longer applies. There the guarantee comes from code signing itself: the
//     helper must have a valid signature AND the app bundle seal covering it must be intact.
//     (Note: on Apple Silicon every executable carries at least a linker ad-hoc signature, so a
//     "valid signature" alone is weak evidence — the bundle seal is what makes this meaningful.)

/// How the engine earned trust, shown in Settings and the self-test.
enum EngineIntegrity: Sendable, Equatable {
    /// Bytes match the pinned upstream digest.
    case pinnedDigest
    /// Signed with the app and sealed by the app bundle's signature.
    case signedBundle

    var summary: String {
        switch self {
        case .pinnedDigest: return "matches the pinned digest"
        case .signedBundle: return "signed and sealed by this app"
        }
    }
}

/// What we know about the czkawka_cli engine.
enum EngineStatus: Sendable, Equatable {
    /// No binary anywhere we look.
    case missing
    /// Found, but not trusted (wrong hash / bad signature / not executable) — carries the reason.
    case unverified(reason: String)
    /// Found and trusted. `version` is the pinned release the digest belongs to.
    case ready(url: URL, version: String, integrity: EngineIntegrity)

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
        case .ready(_, let version, let integrity):
            return "\(version) — \(integrity.summary)"
        }
    }
}

/// Locates the czkawka engine and ffmpeg, and verifies the engine before it is ever executed.
enum EngineLocator {

    /// Release + digest pinned in Engines/README.md. Bump both together.
    static let pinnedVersion = "czkawka_cli 12.0.2"
    static let pinnedSHA256 = "3362df5776b209b6365482768bc960e5a853f1b554787954c4a4c64e90bc2c75"

    static let engineName = "czkawka_cli"

    // MARK: Locations

    /// Search order: explicit override, next to the app executable, Contents/Helpers, then the
    /// developer checkout. The checkout fallback is what makes `swift run` and the tests work
    /// without bundling.
    static func candidateURLs(fileManager: FileManager = .default) -> [URL] {
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SUPERCLEAN_ENGINE"], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override))
        }
        if let executable = Bundle.main.executableURL {
            urls.append(executable.deletingLastPathComponent().appendingPathComponent(engineName))
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

    /// Full check: exists, executable, trusted. Cheap enough to run once per launch.
    /// `candidates`, `bundleURL` and `signatureTrusted` are injectable so the rules stay testable
    /// without the real binary, a signed bundle, or shelling out to codesign.
    static func locate(
        candidates: [URL]? = nil,
        expectedDigest: String = pinnedSHA256,
        bundleURL: URL? = Bundle.main.bundleURL,
        fileManager: FileManager = .default,
        signatureTrusted: (URL) -> Bool = isSignedByBundle
    ) -> EngineStatus {
        for url in candidates ?? candidateURLs(fileManager: fileManager) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard fileManager.isExecutableFile(atPath: url.path) else {
                return .unverified(reason: "not executable: \(url.path)")
            }

            // Fast path and the only path for a developer checkout: match the upstream bytes.
            if let digest = try? sha256(ofFileAt: url) {
                if digest == expectedDigest {
                    return .ready(url: url, version: pinnedVersion, integrity: .pinnedDigest)
                }
                if isInsideBundle(url, bundleURL: bundleURL) {
                    // Expected: signing the bundled copy changed its bytes. Fall through to the
                    // signature check rather than rejecting it.
                    if signatureTrusted(url) {
                        return .ready(url: url, version: pinnedVersion, integrity: .signedBundle)
                    }
                    return .unverified(reason: "bundled copy is neither the pinned build nor signed by this app")
                }
                return .unverified(reason: "hash mismatch (got \(digest.prefix(12))…)")
            } else {
                return .unverified(reason: "unreadable: \(url.path)")
            }
        }
        return .missing
    }

    private static func isInsideBundle(_ url: URL, bundleURL: URL?) -> Bool {
        guard let bundlePath = bundleURL?.standardizedFileURL.path else { return false }
        return url.standardizedFileURL.path.hasPrefix(bundlePath + "/")
    }

    /// True when the binary has a valid code signature and the app bundle that contains it is
    /// itself still validly signed — the seal covers every nested file, including this engine.
    static func isSignedByBundle(engineURL: URL) -> Bool {
        guard isCodeValid(engineURL) else { return false }
        let bundleURL = Bundle.main.bundleURL
        // A raw SwiftPM binary (or a test process) has no real bundle to vouch for the helper.
        guard bundleURL.pathExtension == "app" else { return false }
        return isCodeValid(bundleURL)
    }

    /// Plain code validity: signed and unmodified since signing.
    static func isCodeValid(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
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

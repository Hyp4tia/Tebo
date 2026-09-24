import Foundation
import Testing
@testable import SuperClean

// MARK: - EngineLocator tests
// The engine decides which files get offered for deletion, so "present but wrong" must never read
// as "ready". These tests use injected candidates: no real czkawka binary needed.

@Suite("EngineLocator")
struct EngineLocatorTests {

    /// Scratch executable file. Returns (url, digest).
    private func makeBinary(contents: Data, executable: Bool = true) throws -> (URL, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("superclean-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("czkawka_cli")
        try contents.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path
        )
        return (url, try EngineLocator.sha256(ofFileAt: url))
    }

    @Test("Hashes a known vector")
    func knownVector() throws {
        // SHA-256 of "abc" — a standard test vector, so the streaming hasher is provably correct.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("superclean-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: url)
        #expect(try EngineLocator.sha256(ofFileAt: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("No candidate anywhere means missing")
    func missingEngine() {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("superclean-absent-\(UUID().uuidString)/czkawka_cli")
        #expect(EngineLocator.locate(candidates: [nowhere]) == .missing)
    }

    @Test("Matching digest is ready")
    func verifiedEngine() throws {
        let (url, digest) = try makeBinary(contents: Data(repeating: 7, count: 4096))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let status = EngineLocator.locate(candidates: [url], expectedDigest: digest)
        #expect(status.isReady)
        #expect(status == .ready(url: url, version: EngineLocator.pinnedVersion))
    }

    @Test("Wrong digest is refused, not run")
    func tamperedEngine() throws {
        let (url, _) = try makeBinary(contents: Data(repeating: 7, count: 4096))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let status = EngineLocator.locate(candidates: [url], expectedDigest: EngineLocator.pinnedSHA256)
        guard case .unverified(let reason) = status else {
            Issue.record("tampered engine must be unverified, got \(status)")
            return
        }
        #expect(reason.contains("hash mismatch"))
        #expect(!status.isReady)
    }

    @Test("Non-executable file is refused")
    func nonExecutableEngine() throws {
        let (url, digest) = try makeBinary(contents: Data(repeating: 1, count: 64), executable: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let status = EngineLocator.locate(candidates: [url], expectedDigest: digest)
        guard case .unverified(let reason) = status else {
            Issue.record("non-executable engine must be unverified, got \(status)")
            return
        }
        #expect(reason.contains("not executable"))
    }

    @Test("First existing candidate wins")
    func candidateOrder() throws {
        let (first, firstDigest) = try makeBinary(contents: Data(repeating: 3, count: 32))
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        let absent = first.deletingLastPathComponent().appendingPathComponent("nope")
        let status = EngineLocator.locate(candidates: [absent, first], expectedDigest: firstDigest)
        #expect(status == .ready(url: first, version: EngineLocator.pinnedVersion))
    }
}

import Foundation
import Testing
@testable import SuperClean

// MARK: - EngineLocator tests
// The engine decides which files get offered for deletion, so "present but wrong" must never read
// as "ready". These tests inject candidates/bundle/signature checks: no real czkawka binary, no
// signed app bundle, and no shelling out to codesign.

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
        #expect(EngineLocator.locate(candidates: [nowhere], bundleURL: nil) == .missing)
    }

    @Test("Pinned digest is ready")
    func verifiedEngine() throws {
        let (url, digest) = try makeBinary(contents: Data(repeating: 7, count: 4096))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let status = EngineLocator.locate(
            candidates: [url], expectedDigest: digest, bundleURL: nil,
            signatureTrusted: { _ in false }   // the digest alone must be enough
        )
        #expect(status == .ready(url: url, version: EngineLocator.pinnedVersion, integrity: .pinnedDigest))
    }

    @Test("Loose copy with wrong bytes is refused even when signed")
    func tamperedLooseEngine() throws {
        let (url, _) = try makeBinary(contents: Data(repeating: 7, count: 4096))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A signature says nothing about which bytes should be there; outside the bundle we insist
        // on the pinned digest.
        let status = EngineLocator.locate(
            candidates: [url], expectedDigest: EngineLocator.pinnedSHA256, bundleURL: nil,
            signatureTrusted: { _ in true }
        )
        guard case .unverified(let reason) = status else {
            Issue.record("tampered loose engine must be unverified, got \(status)")
            return
        }
        #expect(reason.contains("hash mismatch"))
    }

    @Test("Bundled copy with signed-seal trust is accepted")
    func bundledSignedEngine() throws {
        // Signing the bundled copy changes its bytes, so trust comes from the app seal instead.
        let (url, _) = try makeBinary(contents: Data(repeating: 9, count: 4096))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let status = EngineLocator.locate(
            candidates: [url], expectedDigest: EngineLocator.pinnedSHA256,
            bundleURL: url.deletingLastPathComponent(),
            signatureTrusted: { _ in true }
        )
        #expect(status == .ready(url: url, version: EngineLocator.pinnedVersion, integrity: .signedBundle))
    }

    @Test("Bundled copy without a valid seal is refused")
    func bundledUnsignedEngine() throws {
        let (url, _) = try makeBinary(contents: Data(repeating: 9, count: 4096))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let status = EngineLocator.locate(
            candidates: [url], expectedDigest: EngineLocator.pinnedSHA256,
            bundleURL: url.deletingLastPathComponent(),
            signatureTrusted: { _ in false }
        )
        guard case .unverified(let reason) = status else {
            Issue.record("unsigned bundled engine must be unverified, got \(status)")
            return
        }
        #expect(reason.contains("neither the pinned build nor signed"))
    }

    @Test("Non-executable file is refused")
    func nonExecutableEngine() throws {
        let (url, digest) = try makeBinary(contents: Data(repeating: 1, count: 64), executable: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let status = EngineLocator.locate(candidates: [url], expectedDigest: digest, bundleURL: nil)
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
        let status = EngineLocator.locate(
            candidates: [absent, first], expectedDigest: firstDigest, bundleURL: nil
        )
        #expect(status == .ready(url: first, version: EngineLocator.pinnedVersion, integrity: .pinnedDigest))
    }
}

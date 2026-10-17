import Foundation
import Testing
@testable import Tebo

// The evidence policy decides which safety evidence a reviewed tool cache may
// tolerate. Every tolerance gets a positive and a negative test: a defect in
// either direction either keeps everything (the reliability bug being fixed)
// or removes something where user repositories or credentials live.

@Suite("Mole evidence policy")
struct EvidencePolicyTests {

    private func fixture() throws -> URL {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ root: URL, _ relative: String, _ contents: String = "fixture cache") throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    @Test("Dependency checkout metadata is tolerated only under the checkouts fragment")
    func checkoutGitIsToleratedOnlyInCheckouts() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("DerivedData/Proj")
        try write(project, "SourcePackages/checkouts/dep/.git/config")
        try write(project, "Local/working/.git/config")

        let checkout = FileTreeMeasurement.read(project.appendingPathComponent("SourcePackages/checkouts"),
            stopAtSafetyEvidence: true, policy: .xcodeBuildCache, containmentRoot: project.path)
        #expect(!checkout.containsRepository)
        #expect(checkout.status == .complete)

        let foreign = FileTreeMeasurement.read(project.appendingPathComponent("Local"),
            stopAtSafetyEvidence: true, policy: .xcodeBuildCache, containmentRoot: project.path)
        #expect(foreign.containsRepository)

        // The same checkout stays blocking under the strict policy.
        let strict = FileTreeMeasurement.read(project.appendingPathComponent("SourcePackages/checkouts"),
            stopAtSafetyEvidence: true, policy: .strict, containmentRoot: project.path)
        #expect(strict.containsRepository)
    }

    @Test("Root-contained symlinks are tolerated; escapes and missing roots fail closed")
    func symlinkContainment() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try write(cache, "wheels/data.bin")
        let contained = cache.appendingPathComponent("archive-v0/link")
        try FileManager.default.createDirectory(at: contained.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: contained.path, withDestinationPath: "../wheels/data.bin")

        let tolerated = FileTreeMeasurement.read(cache, stopAtSafetyEvidence: true,
            policy: .developerCache, containmentRoot: cache.path)
        #expect(!tolerated.containsSymbolicLinks)
        #expect(tolerated.status == .complete)

        // A link that leaves the rule root blocks, as does an unknown root.
        let escape = cache.appendingPathComponent("archive-v0/escape")
        try FileManager.default.createSymbolicLink(atPath: escape.path,
            withDestinationPath: root.appendingPathComponent("outside.bin").path)
        #expect(FileTreeMeasurement.read(cache, stopAtSafetyEvidence: true,
            policy: .developerCache, containmentRoot: cache.path).containsSymbolicLinks)
        #expect(FileTreeMeasurement.read(cache, stopAtSafetyEvidence: true,
            policy: .developerCache, containmentRoot: nil).containsSymbolicLinks)

        // Strict policy keeps even the contained link blocking.
        #expect(FileTreeMeasurement.read(cache, stopAtSafetyEvidence: true,
            policy: .strict, containmentRoot: cache.path).containsSymbolicLinks)
    }

    @Test("Only the exact embedded provisioning payload is tolerated by name")
    func embeddedProvisioningToleranceIsExact() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let derivedData = root.appendingPathComponent("DerivedData")
        let provisioning = try write(derivedData, "Proj/Build/Products/Debug/Foo.app/embedded.mobileprovision")
        #expect(FileTreeMeasurement.read(provisioning, stopAtSafetyEvidence: true,
            policy: .xcodeBuildCache, containmentRoot: derivedData.path).containsCredentials == false)

        let named = try write(derivedData, "Proj2/Build/Products/Debug/Bar.app/DevProfile.mobileprovision")
        #expect(FileTreeMeasurement.read(named, stopAtSafetyEvidence: true,
            policy: .xcodeBuildCache, containmentRoot: derivedData.path).containsCredentials)

        let key = try write(derivedData, "Proj3/certs/signing.pem", "PRIVATE KEY")
        #expect(FileTreeMeasurement.read(key, stopAtSafetyEvidence: true,
            policy: .xcodeBuildCache, containmentRoot: derivedData.path).containsCredentials)

        let dotenv = try write(derivedData, "Proj4/.env")
        #expect(FileTreeMeasurement.read(dotenv, stopAtSafetyEvidence: true,
            policy: .developerCache, containmentRoot: derivedData.path).containsCredentials)
    }
}

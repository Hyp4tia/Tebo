import Foundation
import Testing
@testable import Tebo

@Suite("Native Mole workflows")
struct MoleWorkspaceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-mole-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ root: URL, _ path: String, _ value: String = "data") throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
        return file
    }
    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
            .replacingOccurrences(of: "/private/var/", with: "/var/")
    }
    private func app(_ root: URL, _ name: String, _ id: String) throws -> URL {
        let url = root.appendingPathComponent("Applications/\(name).app")
        let info: [String: String] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.0"]
        let path = url.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path)
        return url
    }

    @Test("Native folder analysis measures real files without either external engine")
    func nativeAnalysis() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "one.txt", "hello")
        _ = try write(root, "sub/two.txt", "world!")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("sub"))
        let report = await NativeDiskAnalyzer().analyze(root.path)
        #expect(report.entries.count == 2)
        #expect(report.bytes == 11)
        #expect(report.status == .partial) // skipped link is disclosed
        #expect(report.entries.allSatisfy { $0.measurement.status == .complete })
        let missing = await NativeDiskAnalyzer().analyze(root.appendingPathComponent("missing").path)
        #expect(missing.status == .unavailable)
        #expect(missing.entries.isEmpty)
        _ = try write(root, "sub/.git/objects/data", "history")
        let updated = await NativeDiskAnalyzer().analyze(root.path)
        #expect(updated.bytes == 18) // repository metadata still occupies disk space
    }

    @Test("Bounded tree scans disclose incomplete measurements")
    func partialSizes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<10 { _ = try write(root, "\(index).txt") }
        let result = FileTreeMeasurement.read(root, entryLimit: 2)
        #expect(result.status == .partial)
        #expect(result.bytes < 40)
        let row = ScanResult(path: root.path, sizeBytes: result.bytes, category: "Folders", reason: "Partial", isSizeComplete: false)
        #expect(row.displaySize.hasPrefix("≥ "))
    }

    @Test("Uninstall plans use exact ownership and protect running/system apps")
    func uninstallOwnership() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try app(root, "Editor", "org.fixture.editor")
        _ = try app(root, "System", "com.apple.fixture")
        let cache = try write(root, "Library/Caches/org.fixture.editor/data")
        _ = try write(root, "Library/Preferences/org.fixture.editor-extra.plist")
        let service = ApplicationUninstaller(applicationRoots: [root.appendingPathComponent("Applications").path], home: root.path)
        let inventory = service.inventory()
        let editor = try #require(inventory.first { $0.path == appURL.path })
        #expect(inventory.first { $0.bundleID == "com.apple.fixture" }?.protectedReason != nil)
        let plan = await service.plan(for: editor, whitelist: [], runningBundleIDs: [])
        #expect(plan.rows.count == 1)
        #expect(plan.rows.first?.category == "Application")
        #expect(!plan.rows.contains { $0.path == cache.deletingLastPathComponent().path })
        #expect(plan.kept.contains { $0.id.hasSuffix("/Caches/org.fixture.editor") })
        #expect(!plan.rows.contains { $0.path.contains("editor-extra") })
        let running = await service.plan(for: editor, whitelist: [], runningBundleIDs: [editor.bundleID])
        #expect(running.rows.isEmpty)
        #expect(!running.kept.isEmpty)
        let helper = await service.plan(for: editor, whitelist: [], runningBundleIDs: [editor.bundleID + ".Helper"])
        #expect(helper.rows.isEmpty)
    }

    @Test("A newly installed copy protects app data at the uninstall boundary")
    func sharedCopyAppears() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try app(root, "First", "org.fixture.shared")
        let cache = try write(root, "Library/Caches/org.fixture.shared/data").deletingLastPathComponent()
        let service = ApplicationUninstaller(applicationRoots: [root.appendingPathComponent("Applications").path], home: root.path)
        let application = try #require(service.inventory().first { $0.path == first.path })
        let plan = await service.plan(for: application, whitelist: [], runningBundleIDs: [])
        _ = try app(root, "Second", "ORG.FIXTURE.SHARED")
        #expect(!plan.rows.contains { $0.path == cache.path })
        #expect(plan.kept.contains { $0.id == cache.path })
        let result = await service.execute(plan, selectedPaths: [cache.path], whitelist: [], runningBundleIDs: [])
        #expect(result.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("A reviewed disposable app and its owned cache go through the Trash pipeline")
    func uninstallFixture() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let unique = UUID().uuidString
        let application = try app(root, "Tebo-Test-\(unique)", "org.fixture.\(unique)")
        let cache = try write(root, "Library/Caches/org.fixture.\(unique)/data").deletingLastPathComponent()
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        defer {
            // Only the uniquely named throwaway items created by this test.
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(application.lastPathComponent))
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(cache.lastPathComponent))
        }
        let service = ApplicationUninstaller(applicationRoots: [root.appendingPathComponent("Applications").path], home: root.path)
        let metadata = try #require(service.inventory().first)
        let plan = await service.plan(for: metadata, whitelist: [], runningBundleIDs: [])
        let report = await service.execute(plan, selectedPaths: Set(plan.rows.map(\.path)), whitelist: [], runningBundleIDs: [])
        #expect(report.trashedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: application.path))
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Files replaced after preview survive the deletion boundary")
    func previewIdentity() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(root, "reviewed.txt", "old")
        let identity = try #require(FileIdentity.read(path: file.path))
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original.txt"))
        _ = try write(root, "reviewed.txt", "new")
        let report = await DeletePipeline().trash(paths: [file.path], whitelist: [], expectedIdentities: [file.path: identity])
        #expect(report.outcomes.first?.result == .skipped(reason: .identityChanged))
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    }

    @Test("Purge protects nested repositories and deployment keys, including hidden artifacts")
    func artifactGuards() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "repo/node_modules/.git/config")
        _ = try write(root, "keys/target/deploy-keypair.json")
        _ = try write(root, "swift/.build/output")
        let service = ProjectArtifactScanner(roots: [root.path])
        let report = await service.scan(whitelist: [])
        #expect(report.rows.isEmpty)
        #expect(report.kept.count == 3)
        #expect(report.kept.contains { $0.id.hasSuffix("/node_modules") })
        #expect(report.kept.contains { $0.id.hasSuffix("/target") })
        #expect(report.kept.contains { $0.id.hasSuffix("/.build") })
    }

    @Test("Project cleanup keeps a newly changed folder unticked even if its files are old")
    func recentFolderActivity() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(root, "project/node_modules/cached.bin")
        let folder = file.deletingLastPathComponent()
        let old = Date.now.addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: folder.path)
        let report = await ProjectArtifactScanner(roots: [root.path]).scan(whitelist: [])
        #expect(report.rows.isEmpty)
        #expect(report.kept.contains { normalizedPath($0.id) == normalizedPath(folder.path) })
        #expect(report.kept.first(where: { normalizedPath($0.id) == normalizedPath(folder.path) })?.detail.localizedCaseInsensitiveContains("review") == true)

        let active = await ProjectArtifactScanner(roots: [root.path]).protectionReason(for: folder, whitelist: [])
        #expect(active?.localizedCaseInsensitiveContains("activity") == true)
    }

    @Test("Purge recognizes Git-tracked authored files")
    func trackedArtifacts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "build/authored.txt")
        let initialized = await BoundedProcessRunner.run(executablePath: "/usr/bin/git", arguments: ["init", root.path], timeout: 5)
        #expect(initialized.terminationStatus == 0)
        let staged = await BoundedProcessRunner.run(executablePath: "/usr/bin/git", arguments: ["-C", root.path, "add", "build/authored.txt"], timeout: 5)
        #expect(staged.terminationStatus == 0)
        let report = await ProjectArtifactScanner(roots: [root.path]).scan(whitelist: [])
        #expect(report.rows.isEmpty)
        #expect(report.kept.contains { $0.id.hasSuffix("/build") && $0.detail.localizedCaseInsensitiveContains("repository") })
    }

    @Test("The process runner drains output larger than a pipe buffer")
    func largeProcessOutput() async {
        let result = await BoundedProcessRunner.run(executablePath: "/usr/bin/jot", arguments: ["30000"], timeout: 5)
        #expect(result.terminationStatus == 0)
        #expect(result.stdout.hasSuffix("30000\n"))
        #expect(!result.outputTruncated)
    }

    @Test("Maintenance scans skip live and protected preferences")
    func maintenanceGuard() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        // A bare word is a valid scalar plist, so use genuinely malformed XML.
        let malformed = "<plist version=\"1.0\"><dict>"
        #expect((try? PropertyListSerialization.propertyList(from: Data(malformed.utf8), format: nil)) == nil)
        _ = try write(root, "Library/Preferences/org.fixture.idle.plist", malformed)
        _ = try write(root, "Library/Preferences/org.fixture.running.plist", malformed)
        _ = try write(root, "Library/Preferences/com.apple.test.plist", malformed)
        let report = await MaintenanceScanner(home: root.path).scan(.brokenPreferences, whitelist: [], runningIDs: ["org.fixture.running"])
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.path.hasSuffix("idle.plist") == true)
        #expect(report.kept.count == 2)
        let idle = try #require(report.rows.first)
        let valid = try PropertyListSerialization.data(fromPropertyList: ["restored": true], format: .xml, options: 0)
        try valid.write(to: URL(fileURLWithPath: idle.path))
        #expect(MaintenanceScanner(home: root.path).removalReason(path: idle.path, mode: .brokenPreferences,
            whitelist: [], runningIDs: []) == "This is a valid property list; file kept")
    }

    @Test("Live rates never invent an initial sample or negative counter delta")
    func sampledRates() {
        #expect(LiveSystemStatus.rate(200, nil, 2) == nil)
        #expect(LiveSystemStatus.rate(50, 100, 2) == nil)
        #expect(LiveSystemStatus.rate(200, 100, 2) == 50)
        #expect(LiveSystemStatus.rate(200, 100, 0) == nil)
    }
}

@Suite("Mole workspace routing") @MainActor
struct MoleWorkspaceRoutingTests {
    @Test("File cleanup excludes duplicate and media-engine workflows")
    func moleOnly() {
        #expect(!CleanupWorkspace.files.pages.contains(.duplicates))
        #expect(!CleanupWorkspace.files.pages.contains(.similarImages))
        #expect(!CleanupWorkspace.files.pages.contains(.downloads))
        #expect(!CleanupWorkspace.files.pages.contains(.archives))
        #expect(CleanupWorkspace.images.pages.contains(.similarImages))
        #expect(CleanupWorkspace.images.pages.contains(.duplicates))
    }
}

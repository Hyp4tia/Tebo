import Foundation
import Testing
@testable import Tebo

@Suite("Project and uninstall safety")
struct ProjectUninstallSafetyTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-project-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ root: URL, _ relativePath: String, _ contents: String = "fixture") throws -> URL {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func physicalPath(_ url: URL) -> String {
        normalizedPath(url.path)
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
            .replacingOccurrences(of: "/private/var/", with: "/var/")
    }

    private func removeFixtureAppFromTrash(_ app: URL) {
        let item = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent(app.lastPathComponent)
        try? FileManager.default.removeItem(at: item)
    }

    private func makeApp(_ root: URL, name: String, bundleID: String) throws -> URL {
        try makeApp(at: root.appendingPathComponent("Applications/\(name).app"), name: name, bundleID: bundleID)
    }

    private func makeApp(at app: URL, name: String, bundleID: String) throws -> URL {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: infoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleShortVersionString": "1.0"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: infoURL)
        return app
    }

    @Test("Uninstall review offers only the app bundle and keeps related user data read-only")
    func uninstallPlanKeepsRelatedData() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleID = "org.fixture.editor"
        let app = try makeApp(root, name: "Editor", bundleID: bundleID)
        let dataPaths = [
            "Library/Caches/\(bundleID)/cache.bin",
            "Library/Application Support/\(bundleID)/documents.db",
            "Library/Preferences/\(bundleID).plist",
            "Library/Saved Application State/\(bundleID).savedState/state.data",
            "Library/WebKit/\(bundleID)/WebsiteData/LocalStorage/data",
            "Library/HTTPStorages/\(bundleID)/cookies.binarycookies",
            "Library/Containers/\(bundleID)/Data/Documents/keep.txt",
            "Library/Group Containers/group.fixture.shared/Data/Documents/shared.txt",
            "Library/Keychains/login.keychain-db"
        ]
        for path in dataPaths { _ = try write(root, path) }
        let launchAgent = try write(root, "Library/LaunchAgents/\(bundleID).plist")
        let launchAgentData = try PropertyListSerialization.data(fromPropertyList: ["Label": bundleID,
            "ProgramArguments": [app.appendingPathComponent("Contents/MacOS/Editor").path]], format: .xml, options: 0)
        try launchAgentData.write(to: launchAgent)

        let service = ApplicationUninstaller(
            applicationRoots: [root.appendingPathComponent("Applications").path], home: root.path
        )
        let metadata = try #require(service.inventory().first)
        let relatedPaths = [
            "Library/Caches/\(bundleID)",
            "Library/Application Support/\(bundleID)",
            "Library/Preferences/\(bundleID).plist",
            "Library/Saved Application State/\(bundleID).savedState",
            "Library/WebKit/\(bundleID)",
            "Library/HTTPStorages/\(bundleID)",
            "Library/Containers/\(bundleID)",
            "Library/Group Containers",
            "Library/Keychains",
            "Library/LaunchAgents/\(bundleID).plist"
        ]
        let plan = await service.plan(for: metadata, whitelist: [], runningBundleIDs: [])
        let dataIDs = Set(relatedPaths.map { physicalPath(root.appendingPathComponent($0)) })

        #expect(plan.rows.map { normalizedPath($0.path) } == [physicalPath(app)])
        #expect(Set(plan.identities.keys.map(normalizedPath)) == [physicalPath(app)])
        #expect(Set(plan.bindings.keys.map(normalizedPath)) == [physicalPath(app)])
        #expect(Set(plan.kept.map { normalizedPath($0.id) }).isSuperset(of: dataIDs))
        #expect(plan.rows.allSatisfy { $0.category == "Application" && !$0.recommendedForSelection })
    }

    private final class ProcessEvidenceSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var evidence: [UninstallProcessEvidence]
        private var index = 0
        private var calls = 0
        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        init(_ evidence: [UninstallProcessEvidence]) { self.evidence = evidence }

        func next() -> UninstallProcessEvidence {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            let result = evidence[min(index, evidence.count - 1)]
            index += 1
            return result
        }
    }

    @Test("A helper process launched after review blocks the app at the final per-item check")
    func helperLaunchAfterPreviewIsBlocked() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(root, name: "Editor-\(UUID().uuidString)", bundleID: "org.fixture.helper")
        defer { removeFixtureAppFromTrash(app) }
        let evidence = ProcessEvidenceSequence([.inactive, .running])
        let service = ApplicationUninstaller(
            applicationRoots: [root.appendingPathComponent("Applications").path],
            home: root.path,
            processProbe: { _ in evidence.next() },
            copyProbe: { _ in .unknown },
            protectionURL: root.appendingPathComponent("whitelist")
        )
        let metadata = try #require(service.inventory().first)
        let plan = await service.plan(for: metadata, whitelist: [], runningBundleIDs: [])
        #expect(plan.rows.contains { normalizedPath($0.path) == physicalPath(app) })

        let report = await service.execute(plan, selectedPaths: [metadata.path], whitelist: [], runningBundleIDs: [])
        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(report.failedCount == 0)
        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(evidence.callCount == 2)
    }

    @Test("Unknown executable inventory keeps the reviewed app")
    func unknownProcessEvidenceKeepsApp() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(root, name: "Editor-\(UUID().uuidString)", bundleID: "org.fixture.unknownprocess")
        defer { removeFixtureAppFromTrash(app) }
        let evidence = ProcessEvidenceSequence([.inactive, .unknown])
        let service = ApplicationUninstaller(
            applicationRoots: [root.appendingPathComponent("Applications").path],
            home: root.path,
            processProbe: { _ in evidence.next() },
            copyProbe: { _ in .unknown },
            protectionURL: root.appendingPathComponent("whitelist")
        )
        let metadata = try #require(service.inventory().first)
        let plan = await service.plan(for: metadata, whitelist: [], runningBundleIDs: [])
        #expect(plan.rows.contains { normalizedPath($0.path) == physicalPath(app) })

        let report = await service.execute(plan, selectedPaths: [metadata.path], whitelist: [], runningBundleIDs: [])
        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(report.failedCount == 0)
        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(evidence.callCount == 2)
    }

    private final class CopyProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
        func record() {
            lock.lock()
            calls += 1
            lock.unlock()
        }
    }

    private func makeDataOnlyPlan(_ plan: UninstallPlan, path: String) throws -> UninstallPlan {
        let identity = try #require(FileIdentity.read(path: path))
        let binding = try #require(PathBinding.read(path: path))
        var identities = plan.identities
        identities[path] = identity
        var bindings = plan.bindings
        bindings[path] = binding
        let row = ScanResult(path: path, sizeBytes: 1, category: "Caches", reason: "stale reviewed data row")
        return UninstallPlan(app: plan.app, rows: [row], identities: identities, bindings: bindings, kept: [])
    }

    @Test("A second app copy discovered after review blocks related-data removal")
    func discoveredSharedCopyAfterPreviewBlocksData() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleID = "org.fixture.knowncopy.\(UUID().uuidString)"
        _ = try makeApp(root, name: "First", bundleID: bundleID)
        let cache = root.appendingPathComponent("Library/Caches/\(bundleID)")
        _ = try write(root, "Library/Caches/\(bundleID)/cache.bin")
        let service = ApplicationUninstaller(
            applicationRoots: [root.appendingPathComponent("Applications").path], home: root.path,
            processProbe: { _ in .inactive }, protectionURL: root.appendingPathComponent("whitelist")
        )
        let metadata = try #require(service.inventory().first)
        let preview = await service.plan(for: metadata, whitelist: [], runningBundleIDs: [])
        let stalePlan = try makeDataOnlyPlan(preview, path: cache.path)
        _ = try makeApp(root, name: "Second", bundleID: bundleID.uppercased())

        let report = await service.execute(stalePlan, selectedPaths: [cache.path], whitelist: [], runningBundleIDs: [])
        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(report.failedCount == 0)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("An external shared app copy appearing after review blocks related-data removal")
    func externalCopyAfterPreviewBlocksData() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleID = "org.fixture.external.\(UUID().uuidString)"
        let app = try makeApp(root, name: "Editor", bundleID: bundleID)
        let cache = root.appendingPathComponent("Library/Caches/\(bundleID)")
        _ = try write(root, "Library/Caches/\(bundleID)/cache.bin")
        let external = root.appendingPathComponent("External/Shared.app")
        let counter = CopyProbeCounter()
        let service = ApplicationUninstaller(
            applicationRoots: [root.appendingPathComponent("Applications").path],
            home: root.path,
            processProbe: { _ in .inactive },
            copyProbe: { _ in
                counter.record()
                return FileManager.default.fileExists(atPath: external.path) ? .sharedCopy : .unknown
            },
            protectionURL: root.appendingPathComponent("whitelist")
        )
        let metadata = try #require(service.inventory().first { $0.path == physicalPath(app) || normalizedPath($0.path) == physicalPath(app) })
        let preview = await service.plan(for: metadata, whitelist: [], runningBundleIDs: [])
        let stalePlan = try makeDataOnlyPlan(preview, path: cache.path)
        _ = try makeApp(at: external, name: "Shared", bundleID: bundleID)

        let report = await service.execute(stalePlan, selectedPaths: [cache.path], whitelist: [], runningBundleIDs: [])
        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(report.failedCount == 0)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(counter.callCount == 1)
    }

    @Test("Unknown copy ownership keeps related app data")
    func unknownCopyOwnershipKeepsData() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleID = "org.fixture.unknown.\(UUID().uuidString)"
        _ = try makeApp(root, name: "Editor", bundleID: bundleID)
        let cache = root.appendingPathComponent("Library/Caches/\(bundleID)")
        _ = try write(root, "Library/Caches/\(bundleID)/cache.bin")
        let counter = CopyProbeCounter()
        let service = ApplicationUninstaller(
            applicationRoots: [root.appendingPathComponent("Applications").path],
            home: root.path,
            processProbe: { _ in .inactive },
            copyProbe: { _ in counter.record(); return .unknown },
            protectionURL: root.appendingPathComponent("whitelist")
        )
        let metadata = try #require(service.inventory().first)
        let preview = await service.plan(for: metadata, whitelist: [], runningBundleIDs: [])
        let stalePlan = try makeDataOnlyPlan(preview, path: cache.path)

        let report = await service.execute(stalePlan, selectedPaths: [cache.path], whitelist: [], runningBundleIDs: [])
        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(report.failedCount == 0)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(counter.callCount == 1)
    }

    @Test("Unreadable protection configuration blocks an otherwise reviewed app uninstall")
    func unreadableProtectionConfigurationKeepsApp() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(root, name: "Editor", bundleID: "org.fixture.badconfig")
        let invalidProtectionURL = root.appendingPathComponent("invalid-whitelist")
        try FileManager.default.createDirectory(at: invalidProtectionURL, withIntermediateDirectories: true)
        let service = ApplicationUninstaller(
            applicationRoots: [root.appendingPathComponent("Applications").path],
            home: root.path,
            processProbe: { _ in .inactive },
            copyProbe: { _ in .unknown },
            protectionURL: invalidProtectionURL
        )
        let metadata = try #require(service.inventory().first)
        let plan = await service.plan(for: metadata, whitelist: [], runningBundleIDs: [])
        #expect(plan.rows.contains { normalizedPath($0.path) == physicalPath(app) })

        let report = await service.execute(plan, selectedPaths: [metadata.path], whitelist: [], runningBundleIDs: [])
        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(report.failedCount == 0)
        #expect(FileManager.default.fileExists(atPath: app.path))
    }

    @Test("Old named folders and ignored exports remain read-only without rebuild evidence")
    func namedArtifactsAreAdvisories() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let buildFile = try write(root, "project/build/output.bin")
        let export = try write(root, "project/dist/customer-export.zip", "unique customer export")
        let generatedExport = try write(root, "project/dist/generated/rebuilt.zip", "tool-generated export")
        _ = try write(root, "project/package.json", #"{"scripts":{"build":"custom"}}"#)
        _ = try write(root, "project/package-lock.json", "lock")
        let patchedDependency = try write(root, "project/node_modules/vendor-lib/index.js", "locally patched dependency")
        let old = Date.now.addingTimeInterval(-30 * 86_400)
        for file in [buildFile, export, generatedExport, patchedDependency] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }
        for directory in [buildFile.deletingLastPathComponent(), export.deletingLastPathComponent(),
                          generatedExport.deletingLastPathComponent(),
                          patchedDependency.deletingLastPathComponent().deletingLastPathComponent(),
                          patchedDependency.deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        }

        let initialized = await BoundedProcessRunner.run(executablePath: "/usr/bin/git", arguments: ["init", root.appendingPathComponent("project").path], timeout: 5)
        #expect(initialized.terminationStatus == 0)
        let ignored = try write(root, "project/.gitignore", "build/\ndist/generated/\nnode_modules/\n")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: ignored.path)
        let projectRoot = root.appendingPathComponent("project")
        let ignoreResult = await BoundedProcessRunner.run(executablePath: "/usr/bin/git", arguments: ["-C", projectRoot.path, "add", ".gitignore", "package.json", "package-lock.json"], timeout: 5)
        #expect(ignoreResult.terminationStatus == 0)
        let ignoredPaths = ["build/output.bin", "dist/generated/rebuilt.zip", "node_modules/vendor-lib/index.js"]
        let checkIgnored = await BoundedProcessRunner.run(executablePath: "/usr/bin/git",
            arguments: ["-C", projectRoot.path, "check-ignore"] + ignoredPaths, timeout: 5)
        #expect(Set(checkIgnored.stdout.split(whereSeparator: { $0.isNewline }).map(String.init)) == Set(ignoredPaths))
        let status = await BoundedProcessRunner.run(executablePath: "/usr/bin/git",
            arguments: ["-C", projectRoot.path, "status", "--porcelain", "--untracked-files=all"], timeout: 5)
        #expect(status.stdout.contains("?? dist/customer-export.zip"))

        let report = await ProjectArtifactScanner(roots: [root.path]).scan(whitelist: [])
        let expectedPaths: Set<String> = [
            physicalPath(buildFile.deletingLastPathComponent()),
            physicalPath(export.deletingLastPathComponent()),
            physicalPath(patchedDependency.deletingLastPathComponent().deletingLastPathComponent())
        ]
        #expect(report.rows.isEmpty)
        #expect(Set(report.kept.map { normalizedPath($0.id) }).isSuperset(of: expectedPaths))
        #expect(report.kept.filter { expectedPaths.contains(normalizedPath($0.id)) }.allSatisfy {
            $0.detail.localizedCaseInsensitiveContains("review") || $0.detail.localizedCaseInsensitiveContains("kept")
        })
    }

    @Test("Old build output, exports and patched dependencies without a repository stay advisories")
    func oldArtifactsWithoutRepositoryAreNotRecommended() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let buildFile = try write(root, "project/build/output.bin")
        let export = try write(root, "project/dist/customer-export.zip", "unique customer export")
        let dependency = try write(root, "project/node_modules/vendor-lib/index.js", "locally patched")
        _ = try write(root, "project/package.json", #"{"scripts":{"build":"custom"}}"#)
        _ = try write(root, "project/package-lock.json", "lock")
        let old = Date.now.addingTimeInterval(-30 * 86_400)
        let artifactDirectories = [buildFile.deletingLastPathComponent(), export.deletingLastPathComponent(),
            dependency.deletingLastPathComponent().deletingLastPathComponent()]
        for file in [buildFile, export, dependency] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }
        for directory in artifactDirectories {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        }

        let scanner = ProjectArtifactScanner(roots: [root.path])
        let report = await scanner.scan(whitelist: [])
        let expected = Set(artifactDirectories.map(physicalPath))
        #expect(report.rows.isEmpty)
        #expect(Set(report.kept.map { normalizedPath($0.id) }).isSuperset(of: expected))
        for path in expected {
            #expect(report.kept.first { normalizedPath($0.id) == path }?.detail.localizedCaseInsensitiveContains("no reviewed tool-specific") == true)
        }
        let finalReason = await scanner.protectionReason(for: buildFile.deletingLastPathComponent(), whitelist: [])
        #expect(finalReason?.localizedCaseInsensitiveContains("no reviewed tool-specific") == true)
    }

    @Test("Repository metadata, worktrees, vendored source and credentials remain protected")
    func protectedProjectContentsStayReadOnly() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let protectedFolders = ["build", "dist", "target", "node_modules", "vendor"]
        for folder in protectedFolders {
            try FileManager.default.createDirectory(at: project.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for marker in ["build/.git", "dist/.hg", "dist/.svn", "node_modules/.worktrees/main/.git"] {
            try FileManager.default.createDirectory(at: project.appendingPathComponent(marker), withIntermediateDirectories: true)
        }
        _ = try write(root, "project/target/.env", "fixture-secret-not-a-real-credential")
        _ = try write(root, "project/vendor/patched-source.swift", "vendored fixture")

        let scanner = ProjectArtifactScanner(roots: [root.path])
        let report = await scanner.scan(whitelist: [])
        let expected = Set(protectedFolders.map { physicalPath(project.appendingPathComponent($0)) })
        #expect(report.rows.isEmpty)
        #expect(Set(report.kept.map { normalizedPath($0.id) }).isSuperset(of: expected))
        #expect(await scanner.protectionReason(for: project.appendingPathComponent("build"), whitelist: [])?.localizedCaseInsensitiveContains("repository") == true)
        #expect(await scanner.protectionReason(for: project.appendingPathComponent("dist"), whitelist: [])?.localizedCaseInsensitiveContains("repository") == true)
        #expect(await scanner.protectionReason(for: project.appendingPathComponent("node_modules"), whitelist: [])?.localizedCaseInsensitiveContains("repository") == true)
        #expect(await scanner.protectionReason(for: project.appendingPathComponent("target"), whitelist: [])?.localizedCaseInsensitiveContains("credentials") == true)
        #expect(await scanner.protectionReason(for: project.appendingPathComponent("vendor"), whitelist: [])?.localizedCaseInsensitiveContains("vendored") == true)
    }

    @Test("Project activity added after preview blocks the final validator")
    func projectActivityMutationAfterPreview() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("project/build")
        let old = Date.now.addingTimeInterval(-30 * 86_400)
        let oldFile = try write(root, "project/build/output.bin")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: artifact.path)

        let scanner = ProjectArtifactScanner(roots: [root.path])
        let preview = await scanner.scan(whitelist: [])
        #expect(preview.rows.isEmpty)
        #expect(preview.kept.contains { normalizedPath($0.id) == physicalPath(artifact) })

        _ = try write(root, "project/build/newly-generated.bin", "written after preview")
        let finalReason = await scanner.protectionReason(for: artifact, whitelist: [])
        #expect(finalReason?.localizedCaseInsensitiveContains("activity") == true)
    }

    @Test("Project activity written during deletion work is refused by the final pipeline validator")
    func projectActivityAtFinalPipelineBoundary() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("project/build")
        let old = Date.now.addingTimeInterval(-30 * 86_400)
        let oldFile = try write(root, "project/build/output.bin")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: artifact.path)
        let identity = try #require(FileIdentity.read(path: artifact.path))
        let binding = try #require(PathBinding.read(path: artifact.path))
        let scanner = ProjectArtifactScanner(roots: [root.path])
        let newFile = artifact.appendingPathComponent("activity-after-preview.bin")

        let report = await DeletePipeline().trash(
            paths: [artifact.path], whitelist: [],
            expectedIdentities: [artifact.path: identity], expectedBindings: [artifact.path: binding],
            requirePreviewIdentity: true, enforceCleanupSafety: true,
            protectionURL: root.appendingPathComponent("whitelist"),
            additionalValidation: { path in
                await scanner.protectionReason(for: URL(fileURLWithPath: path), whitelist: [])
            },
            beforeMove: { _ in
                try? Data("new project activity".utf8).write(to: newFile)
            }
        )

        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(report.failedCount == 0)
        #expect(FileManager.default.fileExists(atPath: newFile.path))
        #expect(FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test("Cloud placeholders are not traversed during project discovery")
    func cloudPlaceholderIsReadOnly() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let placeholder = root.appendingPathComponent("project/cloud-build")
        try FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: true)
        _ = try write(root, "project/cloud-build/placeholder-content.bin")
        let scanner = ProjectArtifactScanner(roots: [root.path], isCloudPlaceholder: {
            normalizedPath($0.path) == normalizedPath(placeholder.path)
        })

        let report = await scanner.scan(whitelist: [])
        #expect(report.rows.isEmpty)
        #expect(report.kept.contains { normalizedPath($0.id) == physicalPath(placeholder) })
        #expect(!report.kept.contains { $0.id.hasSuffix("placeholder-content.bin") })
    }
}

import Foundation
import Testing
@testable import Tebo

@Suite("Cleanup final removal boundary")
struct CleanupRemovalBoundaryTests {
    @Test("A reviewed closed fixture passes all Mole guards and its bytes can be restored from Trash")
    func guardedFixtureCanBeRestored() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-recover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("tebo-recover-\(UUID().uuidString).bin")
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(file.lastPathComponent)")
        try #require(!FileManager.default.fileExists(atPath: trash.path))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: trash)
        }
        let bytes = Data("generated cache fixture, restored unchanged".utf8)
        try bytes.write(to: file)
        let binding = try #require(PathBinding.read(path: file.path))
        let report = await DeletePipeline().trash(paths: [file.path], whitelist: [],
            expectedIdentities: [file.path: binding.leaf], expectedBindings: [file.path: binding],
            requirePreviewIdentity: true, enforceCleanupSafety: true,
            protectionURL: root.appendingPathComponent("whitelist"), additionalValidation: { _ in nil })
        #expect(report.trashedCount == 1)
        #expect(report.freedBytes == Int64(bytes.count))
        try #require(FileManager.default.fileExists(atPath: trash.path))
        try FileManager.default.moveItem(at: trash, to: file)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("Protected descendants added during awaited source validation keep an unchanged parent")
    func nestedChangeDuringValidationIsKept() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-final-tree-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: nested.appendingPathComponent("data.bin"))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(root.lastPathComponent)"))
        }
        let identity = try #require(FileIdentity.read(path: root.path))
        let binding = try #require(PathBinding.read(path: root.path))
        let model = nested.appendingPathComponent("model.mlmodelc/weights.bin")
        let report = await DeletePipeline().trash(paths: [root.path], whitelist: [],
            expectedIdentities: [root.path: identity], expectedBindings: [root.path: binding],
            requirePreviewIdentity: true, enforceCleanupSafety: true,
            additionalValidation: { _ in
                do {
                    try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("protected model".utf8).write(to: model)
                    #expect(PathBinding.read(path: root.path) == binding)
                    return nil
                } catch {
                    Issue.record(error)
                    return "Fixture setup failed"
                }
            })
        #expect(report.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: model.path))
    }

    @Test("Cancellation still reports an explicit outcome for every reviewed path")
    func cancelledBatchAccountsForEveryPath() async {
        let paths = ["/Users/fixture/cancelled-a", "/Users/fixture/cancelled-b"]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await DeletePipeline().trash(paths: paths, whitelist: [])
        }
        let report = await task.value
        #expect(report.outcomes.map(\.path) == paths)
        #expect(report.skippedCount == paths.count)
        #expect(report.outcomes.allSatisfy { $0.result == .skipped(reason: .cancelled) })
    }

    @Test("An in-place edit with the same inode and size invalidates reviewed removal")
    func sameInodeContentChangeIsKept() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-content-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("changed-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(file.lastPathComponent)"))
        }
        try Data(repeating: 0x41, count: 8).write(to: file)
        let identity = try #require(FileIdentity.read(path: file.path))
        let binding = try #require(PathBinding.read(path: file.path))
        let report = await DeletePipeline().trash(paths: [file.path], whitelist: [],
            expectedIdentities: [file.path: identity], expectedBindings: [file.path: binding],
            requirePreviewIdentity: true, beforeMove: { path in
                try? Data(repeating: 0x42, count: 8).write(to: URL(fileURLWithPath: path))
                #expect(FileIdentity.read(path: path) == identity)
            })
        #expect(report.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Mole removals keep a reviewed file that has become open")
    func activeFileIsKeptAtSink() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-active-sink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("active-\(UUID().uuidString).download")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(file.lastPathComponent)"))
        }
        try Data("download".utf8).write(to: file)
        let identity = try #require(FileIdentity.read(path: file.path))
        let binding = try #require(PathBinding.read(path: file.path))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let report = await DeletePipeline().trash(paths: [file.path], whitelist: [],
            expectedIdentities: [file.path: identity], expectedBindings: [file.path: binding],
            requirePreviewIdentity: true, enforceCleanupSafety: true, additionalValidation: { _ in nil })
        #expect(report.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A Mole removal without reviewed identity evidence is refused")
    func missingPreviewEvidenceIsKept() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cache.bin")
        try Data("keep".utf8).write(to: file)
        let report = await DeletePipeline().trash(paths: [file.path], whitelist: [], requirePreviewIdentity: true)
        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Retargeting a parent link cannot authorize another hard link to the same inode")
    func physicalParentRetargetIsKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-parent-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let name = "bound-\(UUID().uuidString).bin"
        let original = first.appendingPathComponent(name), other = second.appendingPathComponent(name)
        let alias = root.appendingPathComponent("alias")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(name)"))
        }
        try Data("keep both links".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: other)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let selected = alias.appendingPathComponent(name)
        let report = await DeletePipeline().trash(paths: [selected.path], whitelist: [], beforeMove: { _ in
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        })
        #expect(report.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("Cancellation during final validation prevents the move")
    func cancellationPreventsMove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("cancelled-\(UUID().uuidString).bin")
        try Data("keep".utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(file.lastPathComponent)"))
        }
        let task = Task {
            await DeletePipeline().trash(paths: [file.path], whitelist: [], beforeMove: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        let report = await task.value
        #expect(report.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Rule validation runs after late filesystem changes, not before them")
    func finalPolicySeesLateChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tebo-final-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            let generatedTrash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(root.lastPathComponent)")
            try? FileManager.default.removeItem(at: generatedTrash)
        }
        try Data("cache".utf8).write(to: root.appendingPathComponent("cache.bin"))
        let report = await DeletePipeline().trash(paths: [root.path], whitelist: [],
            additionalValidation: { path in
                FileManager.default.fileExists(atPath: path + "/keep.txt") ? "New protected content; kept" : nil
            }, beforeMove: { path in
                try? Data("keep".utf8).write(to: URL(fileURLWithPath: path + "/keep.txt"))
            })
        #expect(report.trashedCount == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path))
    }
}

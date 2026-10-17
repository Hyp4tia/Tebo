import Foundation
import Testing
@testable import Tebo

@Suite("Cleanup active-file guards")
struct CleanupActivityGuardTests {
    @Test("Failed, truncated and ambiguous open-handle probes remain unknown", arguments: [
        BoundedProcessRunner.Result(terminationStatus: nil, stdout: "", stderr: "launch failed"),
        BoundedProcessRunner.Result(terminationStatus: 15, stdout: "", stderr: "timeout"),
        BoundedProcessRunner.Result(terminationStatus: 1, stdout: "", stderr: "unreadable process"),
        BoundedProcessRunner.Result(terminationStatus: 1, stdout: "", stderr: "", outputTruncated: true),
        BoundedProcessRunner.Result(terminationStatus: 0, stdout: "", stderr: "")
    ])
    func incompleteProbeIsKept(result: BoundedProcessRunner.Result) async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-probe-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cache.bin")
        try Data("fixture".utf8).write(to: file)
        #expect(await CleanupActivityGuard.status(for: file.path, probe: { _, _, _ in result }) == .unknown)
    }

    @Test("Open sidecars protect files regardless of filename extension", arguments: ["history.sqlite", "History"])
    func openSidecarIsKept(name: String) async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(name)
        let sidecar = URL(fileURLWithPath: file.path + "-wal")
        try Data("fixture file".utf8).write(to: file)
        try Data("fixture sidecar".utf8).write(to: sidecar)
        let handle = try FileHandle(forReadingFrom: sidecar)
        defer { try? handle.close() }
        #expect(await CleanupActivityGuard.status(for: file.path) == .inUse)
        try handle.close()
        #expect(await CleanupActivityGuard.status(for: file.path) == .idle)
    }

    @Test("Real open files are kept and closed fixture files can pass the probe")
    func realOpenHandle() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("partial.download")
        try Data("fixture download".utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        #expect(await CleanupActivityGuard.status(for: file.path) == .inUse)
        #expect(await CleanupActivityGuard.status(for: root.path) == .inUse)
        try handle.close()
        #expect(await CleanupActivityGuard.status(for: file.path) == .idle)
        #expect(await CleanupActivityGuard.status(for: root.path) == .idle)
    }
}

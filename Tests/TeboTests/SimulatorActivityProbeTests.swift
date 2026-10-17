import Foundation
import Testing
@testable import Tebo

// Simulator-owned data must never be touched while a device is booted, and the
// booted-device probe costs seconds, so Mole brackets it between two process
// checks (_probe_simulator_activity). These tests pin the tri-state, the
// once-per-scan memoization and the removal bracket.

@Suite("Simulator activity probe")
struct SimulatorActivityProbeTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [TimeInterval?]] = [:]
        private var probeCount = 0

        func record(path: String, timeout: TimeInterval?) {
            lock.withLock { entries[path, default: []].append(timeout) }
        }

        func countProbe() {
            lock.withLock { probeCount += 1 }
        }

        var timeoutsByPath: [String: [TimeInterval?]] { lock.withLock { entries } }
        var probes: Int { lock.withLock { probeCount } }
    }

    private let idleLsof: CleanupActivityGuard.Probe = { _, _, _ in
        BoundedProcessRunner.Result(terminationStatus: 1, stdout: "", stderr: "")
    }

    private func fixtureHome() throws -> URL {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = base.appendingPathComponent("tebo-simprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ root: URL, _ relative: String, _ contents: String = "simulator cache") throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    /// One non-empty expansion for every probe-guarded developer target.
    private func installSimulatorFixtures(_ home: URL) throws {
        try write(home, "Library/Developer/CoreSimulator/Caches/dyld_sim/cache.bin")
        try write(home, "Library/Logs/CoreSimulator/old.log")
        try write(home, "Library/Developer/CoreSimulator/Devices/U1/data/tmp/temp.bin")
        try write(home, "Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/System/Library/Caches/blob.bin")
        try write(home, "Library/Developer/XCTestDevices/UUID-1/Clone/data.bin")
    }

    @Test("Booted-device classification matches Mole's response check")
    func classification() {
        #expect(SimulatorActivityProbe.classify(deviceListJSON: #"{"devices":{}}"#) == .idle)
        #expect(SimulatorActivityProbe.classify(
            deviceListJSON: #"{"devices":{"ABC":[{"udid":"x","state":"Booted"}]}}"#) == .active)
        #expect(SimulatorActivityProbe.classify(deviceListJSON: "not json") == .unknown)
        #expect(SimulatorActivityProbe.classify(deviceListJSON: "") == .unknown)
    }

    @Test("The live probe resolves the real simulator state without guessing")
    func liveProbeClassifies() async {
        // Unknown is reserved for a failed or unreadable probe; on a machine
        // with developer tools the command must produce a classified answer.
        #expect(await SimulatorActivityProbe.live() != .unknown)
    }

    @Test("A booted simulator defers simulator-owned rows but not build caches")
    func activeSimulatorDefersSimulatorRows() async throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try installSimulatorFixtures(home)
        try write(home, "Library/Developer/Xcode/DerivedData/Proj-a/Build/x.bin")

        let recorder = Recorder()
        let active = await TargetScanner(home: home.path, runningProcessNames: [], runningProcessPaths: [],
            simulatorActivityProbe: {
                recorder.countProbe()
                return .active
            },
            activityProbe: idleLsof
        ).scan(targets: DeveloperTools.all, whitelist: [])

        #expect(active.deletable.contains { $0.path.contains("DerivedData/Proj-a") })
        #expect(!active.deletable.contains {
            $0.path.contains("CoreSimulator") || $0.path.contains("XCTestDevices")
        })
        #expect(active.advisories.contains { $0.detail.contains("A simulator is booted") })
        // Five probe-guarded targets exist; one probe answer serves the scan.
        #expect(recorder.probes == 1)

        let unknown = await TargetScanner(home: home.path, runningProcessNames: [], runningProcessPaths: [],
            simulatorActivityProbe: { .unknown }, activityProbe: idleLsof
        ).scan(targets: DeveloperTools.all, whitelist: [])
        #expect(!unknown.deletable.contains { $0.path.contains("CoreSimulator") })
        #expect(unknown.advisories.contains { $0.detail.contains("could not be verified") })

        let idle = await TargetScanner(home: home.path, runningProcessNames: [], runningProcessPaths: [],
            simulatorActivityProbe: { .idle }, activityProbe: idleLsof
        ).scan(targets: DeveloperTools.all, whitelist: [])
        for expected in ["CoreSimulator/Caches/dyld_sim", "Logs/CoreSimulator/old.log",
                         "data/tmp/temp.bin", "RuntimeRoot/System/Library/Caches/blob.bin",
                         "XCTestDevices/UUID-1"] {
            #expect(idle.deletable.contains { $0.path.contains(expected) }, "missing row for \(expected)")
        }
        #expect(idle.deletable.allSatisfy { $0.recommendedForSelection })
    }

    @Test("Removal re-probes the device state and re-checks processes after the probe")
    func removalBracket() async throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = try write(home, "Library/Developer/CoreSimulator/Caches/dyld_sim/cache.bin")
        let target = try #require(DeveloperTools.all.first { $0.label == "Simulator caches" })
        let candidate = cache.deletingLastPathComponent().path
        let inventory = MoleProcessInventory(names: [], executablePaths: [])

        func reason(
            probe: @escaping SimulatorActivityProbe.Probe,
            refresh: (@Sendable () async -> MoleProcessInventory?)? = nil
        ) async -> String? {
            await TargetScanner(home: home.path, processInventory: inventory,
                simulatorActivityProbe: probe, inventoryRefresh: refresh, activityProbe: idleLsof
            ).removalProtectionReason(for: candidate, ruleID: target.ruleID, whitelist: [], targets: [target])
        }

        #expect(await reason(probe: { .idle }) == nil)
        #expect(await reason(probe: { .active })?.contains("simulator is booted") == true)
        #expect(await reason(probe: { .unknown })?.contains("could not be verified") == true)

        // The bracket's second half: the probe answered idle, but the fresh
        // inventory shows Xcode tooling started while it ran. The refusal
        // carries the guard family the rows defer to.
        let flipped = await reason(probe: { .idle }, refresh: {
            MoleProcessInventory(names: ["xcodebuild"], executablePaths: [])
        })
        #expect(flipped?.contains("Simulator is running") == true)
    }
}

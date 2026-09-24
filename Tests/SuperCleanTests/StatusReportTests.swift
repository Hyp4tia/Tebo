import Foundation
import Testing
@testable import SuperClean

// MARK: - StatusReport tests
// All metrics come from injected fake providers, so no assertion depends
// on this machine's disk/RAM/CPU state. The one native-reader test only
// asserts invariants (values are nil or in range), never concrete numbers.

@Suite("StatusReport")
struct StatusReportTests {

    static func fakeProviders() -> StatusProviders {
        StatusProviders(
            disk: { volumePath in
                DiskStatus(volumePath: volumePath, totalBytes: 100, availableBytes: 40, opportunisticBytes: 10)
            },
            memory: { MemoryStatus(totalBytes: 1600, freeBytes: 400) },
            uptime: { 3600 },
            processorCount: { 8 },
            activeProcessorCount: { 6 },
            physicalCoreCount: { 4 },
            osVersion: { "macOS 26.0" }
        )
    }

    @Test("Report assembles injected provider values")
    func assemblesProviderValues() {
        let report = StatusReport(providers: Self.fakeProviders()).collect()

        #expect(report.disk.volumePath == "/")
        #expect(report.disk.totalBytes == 100)
        #expect(report.disk.availableBytes == 40)
        #expect(report.disk.opportunisticBytes == 10)
        #expect(report.disk.usedFraction == 0.6)
        #expect(report.memory.totalBytes == 1600)
        #expect(report.memory.freeBytes == 400)
        #expect(report.memory.usedFraction == 0.75)
        #expect(report.uptimeSeconds == 3600)
        #expect(report.processorCount == 8)
        #expect(report.activeProcessorCount == 6)
        #expect(report.physicalCoreCount == 4)
        #expect(report.osVersionString == "macOS 26.0")
        #expect(abs(report.collectedAt.timeIntervalSinceNow) < 5)
    }

    @Test("Nil provider values stay nil so the UI can show unavailable")
    func nilMetricsStayNil() {
        let providers = StatusProviders(
            disk: { volumePath in
                DiskStatus(volumePath: volumePath, totalBytes: nil, availableBytes: nil, opportunisticBytes: nil)
            },
            memory: { MemoryStatus(totalBytes: nil, freeBytes: nil) },
            uptime: { nil },
            processorCount: { nil },
            activeProcessorCount: { nil },
            physicalCoreCount: { nil },
            osVersion: { nil }
        )
        let report = StatusReport(providers: providers).collect()

        #expect(report.disk.totalBytes == nil)
        #expect(report.disk.availableBytes == nil)
        #expect(report.disk.usedFraction == nil)
        #expect(report.memory.totalBytes == nil)
        #expect(report.memory.freeBytes == nil)
        #expect(report.memory.usedFraction == nil)
        #expect(report.uptimeSeconds == nil)
        #expect(report.processorCount == nil)
        #expect(report.physicalCoreCount == nil)
        #expect(report.osVersionString == nil)
    }

    @Test("Used fractions clamp to 0...1 and unknown totals are nil")
    func fractionsClamp() {
        let overfull = DiskStatus(volumePath: "/", totalBytes: 100, availableBytes: 120, opportunisticBytes: nil)
        #expect(overfull.usedFraction == 0)

        let unknown = DiskStatus(volumePath: "/", totalBytes: 0, availableBytes: 0, opportunisticBytes: nil)
        #expect(unknown.usedFraction == nil)

        let fullMemory = MemoryStatus(totalBytes: 100, freeBytes: 0)
        #expect(fullMemory.usedFraction == 1)

        let overFreeMemory = MemoryStatus(totalBytes: 100, freeBytes: 250)
        #expect(overFreeMemory.usedFraction == 0)
    }

    @Test("Native disk reader uses Foundation resource values without failing")
    func nativeDiskReader() {
        let disk = StatusProviders.nativeDisk(volumePath: "/")
        #expect(disk.volumePath == "/")
        // Only invariants: real numbers are this machine's business, and
        // the contract is that a failed read is nil, never a guess.
        if let fraction = disk.usedFraction {
            #expect(fraction >= 0 && fraction <= 1)
        }
    }
}

// MARK: - TimeMachineSnapshots tests
// The tmutil probe is faked end to end; only parsing and report assembly
// are exercised. No Process is spawned in these tests.

@Suite("TimeMachineSnapshots")
struct TimeMachineSnapshotsTests {

    struct FakeLister: SnapshotListing {
        let result: SnapshotListingResult
        func listLocalSnapshots() async -> SnapshotListingResult { result }
    }

    @Test("Parses Mole's snapshot name format")
    func parsesSnapshotNames() throws {
        let output = """
        Snapshots for volume group containing disk /System/Volumes/Data:
        com.apple.TimeMachine.2026-09-24-130000.local
        com.apple.TimeMachine.2026-09-23-044530.local
        Deleted 0 local snapshots
        """
        let snapshots = TimeMachineSnapshots.parseSnapshotNames(from: output)

        #expect(snapshots.count == 2)
        #expect(snapshots[0].name == "com.apple.TimeMachine.2026-09-24-130000.local")
        #expect(snapshots[1].name == "com.apple.TimeMachine.2026-09-23-044530.local")
        let date = try #require(snapshots[0].date)
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 24)
        #expect(components.hour == 13)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    @Test("Unexpected output shape yields zero rows, not guesses")
    func ignoresNonSnapshotLines() {
        let snapshots = TimeMachineSnapshots.parseSnapshotNames(from: "garbage\nlines\nnot-a-snapshot\n")
        #expect(snapshots.isEmpty)
    }

    @Test("Successful probe produces a counted report")
    func successfulProbe() async {
        let lister = FakeLister(result: SnapshotListingResult(
            status: .succeeded,
            output: "com.apple.TimeMachine.2026-09-24-130000.local\n",
            detail: nil
        ))
        let report = await TimeMachineSnapshots(lister: lister).list()

        #expect(report.status == .succeeded)
        #expect(report.count == 1)
        #expect(report.snapshots.first?.name == "com.apple.TimeMachine.2026-09-24-130000.local")
        #expect(report.detail == nil)
    }

    @Test("Probe failures are reported, never fabricated")
    func failedProbes() async {
        let cases: [(SnapshotProbeStatus, String)] = [
            (.timedOut, "tmutil timed out after 3s"),
            (.unavailable, "tmutil could not be launched"),
            (.failed, "tmutil exited with status 64"),
        ]
        for (status, detail) in cases {
            let lister = FakeLister(result: SnapshotListingResult(status: status, output: "", detail: detail))
            let report = await TimeMachineSnapshots(lister: lister).list()
            #expect(report.status == status)
            #expect(report.snapshots.isEmpty)
            #expect(report.count == 0)
            #expect(report.detail == detail)
        }
    }
}

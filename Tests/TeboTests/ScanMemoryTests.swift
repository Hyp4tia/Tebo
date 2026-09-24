import Foundation
import Testing
@testable import Tebo

// MARK: - Scan memory guard
// Guards the RAM claim: repeated scans must not grow the process footprint.
//
// Why a control run first: this binary and the Swift runtime allocate lazily, so a raw "footprint
// grew by N" number is not evidence of a leak. The test measures an equal number of awaited no-ops
// and subtracts that drift, so it fails on a real leak (a file-walking API that retains, for
// example `FileManager.enumerator(atPath:)`, which measured ~0.3 MB per pass) and not on noise.

@Suite("Scan memory", .serialized)
struct ScanMemoryTests {

    private static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private static func makeFixture(directories: Int, filesEach: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tebo-mem-\(UUID().uuidString)")
        for index in 0..<directories {
            let directory = root.appendingPathComponent("Library/Caches/app\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<filesEach {
                try Data(repeating: 0x41, count: 256 * (file + 1))
                    .write(to: directory.appendingPathComponent("f\(file).bin"))
            }
        }
        return root
    }

    private static func fixtureTargets() -> [CleanTarget] {
        [
            CleanTarget(
                label: "sweep", group: .appCaches, path: .homeRelative("Library/Caches"),
                kind: .directorySweep, explanation: "memory fixture", source: "test"
            ),
            CleanTarget(
                label: "glob", group: .appCaches, path: .homeRelative("Library/Caches/app1*"),
                kind: .glob, explanation: "memory fixture", source: "test"
            ),
        ]
    }

    @Test("30 scans do not grow the footprint")
    func scansDoNotLeak() async throws {
        let home = try Self.makeFixture(directories: 40, filesEach: 10)
        defer { try? FileManager.default.removeItem(at: home) }

        let scanner = TargetScanner(home: home.path, runningProcessNames: [])
        let targets = Self.fixtureTargets()
        let rounds = 30

        // Warm up once so first-touch allocations land outside the measured window.
        _ = await scanner.scan(targets: targets, whitelist: [])

        let controlStart = Self.footprintBytes()
        for _ in 0..<rounds { await Task.yield() }
        let controlDrift = Self.footprintBytes() - controlStart

        let scanStart = Self.footprintBytes()
        var lastRows = 0
        for _ in 0..<rounds {
            lastRows = await scanner.scan(targets: targets, whitelist: []).deletable.count
        }
        let scanDrift = Self.footprintBytes() - scanStart

        let attributed = scanDrift - max(controlDrift, 0)
        let megabyte = 1_048_576.0
        print(String(
            format: "scan memory: %d rounds, %d rows, control %+.2f MB, scans %+.2f MB, attributed %+.2f MB",
            rounds, lastRows, Double(controlDrift) / megabyte, Double(scanDrift) / megabyte,
            Double(attributed) / megabyte
        ))

        #expect(lastRows > 0, "fixture must produce rows, otherwise this test proves nothing")
        #expect(
            attributed < 8 * 1_048_576,
            "30 scans drifted \(Double(attributed) / megabyte) MB beyond the control run"
        )
    }
}

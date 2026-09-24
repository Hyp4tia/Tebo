import Foundation

// MARK: - SelfTest
// Headless entry point: `SuperClean --selftest` prints what the app can actually see on this machine
// and exits. scripts/verify.sh runs it, and the M6 memory/perf audit drives it instead of the GUI,
// so the numbers in docs/AUDIT.md come from a real process rather than from clicking around.

enum SelfTest {

    /// True when the process was launched with --selftest (the caller then exits).
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    /// `--benchmark` or `--benchmark=20`: run the scan pipeline repeatedly and report memory.
    /// Exists so the RAM claim in the audit is measured on a real process, not asserted.
    static var benchmarkIterations: Int? {
        for argument in CommandLine.arguments {
            if argument == "--benchmark" { return 10 }
            if argument.hasPrefix("--benchmark=") {
                return Int(argument.dropFirst("--benchmark=".count)) ?? 10
            }
        }
        return nil
    }

    static func run() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"

        print("SuperClean self-test")
        print("bundle          \(Bundle.main.bundleIdentifier ?? "no bundle id") \(version)")

        let engine = EngineLocator.locate()
        switch engine {
        case .ready(let url, let pinnedVersion, let integrity):
            print("engine          \(pinnedVersion) — \(integrity.summary)")
            print("engine path     \(url.path)")
        case .missing:
            print("engine          missing (run scripts/fetch-engine.sh)")
        case .unverified(let reason):
            print("engine          REFUSED — \(reason)")
        }

        print("ffmpeg          \(EngineLocator.findFFmpeg() ?? "not installed")")

        let fda = PermissionProbe.hasFullDiskAccess()
        print("full disk       \(fda ? "granted" : "denied")")

        let whitelist = WhitelistStore.load()
        print("whitelist       \(whitelist.count) entries in \(WhitelistStore.fileURL().path)")

        print("log             \(OperationLog.fileURL().path)")
        print("dry-run         on by default; deletes only via DeletePipeline")
    }

    // MARK: - Benchmark (memory evidence)

    /// Repeated scans over a generated tree, printing the process footprint each round.
    /// A leak shows up as a footprint that keeps climbing with the iteration count; a healthy
    /// pipeline plateaus once the autorelease pools drain.
    static func benchmark(iterations: Int) async {
        print("SuperClean benchmark")
        print("iterations      \(iterations)")

        let root: URL
        do {
            root = try makeFixtureTree(directoryCount: 40, filesPerDirectory: 10)
        } catch {
            print("fixture         FAILED to build: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }
        print("fixture         \(root.path)")

        let targets = fixtureTargets()
        let scanner = TargetScanner(home: root.path, runningProcessNames: [])

        print("")
        print("round   rows     footprint   delta")
        var baseline: Int64 = 0
        var rows = 0
        for iteration in 1...iterations {
            let started = Date()
            let outcome = await scanner.scan(targets: targets, whitelist: [])
            rows = outcome.deletable.count
            let footprint = currentFootprintBytes()
            if iteration == 1 { baseline = footprint }
            let delta = footprint - baseline
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            print(String(
                format: "%5d   %5d   %8.1f MB   %+7.1f MB   (%@s)",
                iteration, rows, Double(footprint) / 1_048_576, Double(delta) / 1_048_576, elapsed
            ))
        }

        // One pass over the real home, so the number that matters is measured too.
        print("")
        let real = TargetScanner(runningProcessNames: [])
        let started = Date()
        let realOutcome = await real.scan(whitelist: [])
        let realElapsed = Date().timeIntervalSince(started)
        let realFootprint = currentFootprintBytes()
        print(String(
            format: "real home scan  %d rows, %d advisories, %d absent in %.1fs, footprint %8.1f MB (delta %+.1f MB)",
            realOutcome.deletable.count, realOutcome.advisories.count, realOutcome.absentLocationCount,
            realElapsed, Double(realFootprint) / 1_048_576, Double(realFootprint - baseline) / 1_048_576
        ))
    }

    /// Small realistic tree: nested caches with files of varying size.
    private static func makeFixtureTree(directoryCount: Int, filesPerDirectory: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("superclean-bench-\(UUID().uuidString)")
        for index in 0..<directoryCount {
            let directory = root.appendingPathComponent("Library/Caches/app\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<filesPerDirectory {
                let bytes = Data(repeating: 0x41, count: 256 * (file + 1))
                try bytes.write(to: directory.appendingPathComponent("file\(file).bin"))
            }
        }
        return root
    }

    /// Table rows aimed at the fixture tree, covering the kinds the scanner implements.
    private static func fixtureTargets() -> [CleanTarget] {
        [
            CleanTarget(
                label: "fixture sweep", group: .appCaches,
                path: .homeRelative("Library/Caches"), kind: .directorySweep,
                explanation: "benchmark rows", source: "benchmark"
            ),
            CleanTarget(
                label: "fixture glob", group: .appCaches,
                path: .homeRelative("Library/Caches/app1*"), kind: .glob,
                explanation: "benchmark rows", source: "benchmark"
            ),
            CleanTarget(
                label: "missing", group: .appCaches,
                path: .homeRelative("Library/Caches/does-not-exist"), kind: .directory,
                explanation: "benchmark rows", source: "benchmark"
            ),
        ]
    }

    /// Resident footprint of this process. task_vm_info is the same number Activity Monitor shows,
    /// so the audit's claim can be checked against Activity Monitor directly.
    private static func currentFootprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }
}

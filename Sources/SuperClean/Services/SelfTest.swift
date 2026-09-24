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

    static func run() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"

        print("SuperClean self-test")
        print("bundle          \(Bundle.main.bundleIdentifier ?? "no bundle id") \(version)")

        let engine = EngineLocator.locate()
        switch engine {
        case .ready(let url, let pinnedVersion):
            print("engine          \(pinnedVersion) verified")
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
}

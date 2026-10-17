import Foundation

/// Booted-simulator evidence for simulator-owned cleanup rules.
///
/// Mole brackets its CoreSimulator and XCTestDevices cleanups around
/// `simctl list devices booted -j` (`lib/clean/dev.sh` `_coresimulator_booted_device_state`):
/// a failed command, an unexpected response, or an unresolvable simctl all mean
/// the active state cannot be established, and unknown must fail closed before
/// system CoreSimulator or XCTest data is removed.
public enum SimulatorActivityProbe {
    public enum State: Sendable, Equatable { case idle, active, unknown }

    /// Probe seam: tests inject one of the states; the default runs the real command.
    public typealias Probe = @Sendable () async -> State

    public static let live: Probe = {
        let result = await BoundedProcessRunner.run(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "booted", "-j"],
            timeout: 10
        )
        // The exit status governs, exactly as in Mole's probe: stderr carries no
        // evidence because a successful listing can include service warnings.
        guard result.terminationStatus == 0, !result.outputTruncated else { return .unknown }
        return classify(deviceListJSON: result.stdout)
    }

    /// Mole's response check: a listing without the `devices` key is not trusted,
    /// any booted device contributes a `udid`, and a valid empty list is idle.
    public static func classify(deviceListJSON: String) -> State {
        guard deviceListJSON.contains("\"devices\"") else { return .unknown }
        return deviceListJSON.contains("\"udid\"") ? .active : .idle
    }
}

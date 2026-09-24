import Darwin
import Foundation

// MARK: - TimeMachineSnapshots
// Read-only listing of local APFS snapshots, ported from Mole's
// clean_local_snapshots (lib/clean/system.sh:1429-1478) but WITHOUT any
// delete surface: Mole's own header marks that section "report only"
// (system.sh:1429), and this app has no removal path here at all - the
// app's DeletePipeline is the only place files may be removed, and nothing
// in this file calls it. The single command is `tmutil listlocalsnapshots /`
// at its absolute path with a hard timeout (system.sh:1465-1466,
// MOLE_TIMEOUT_SHORT_QUERY_SEC = 3s).

// MARK: Models

/// One local snapshot. `date` is parsed from the name's YYYY-MM-DD-HHMMSS
/// stamp (local time, the way tmutil prints it).
public struct LocalSnapshot: Identifiable, Hashable, Sendable {
    public var id: String { name }
    /// e.g. "com.apple.TimeMachine.2026-09-24-130000.local".
    public let name: String
    /// nil only when the name matched but the stamp could not be parsed
    /// (not expected in practice; the regex captures only digits).
    public let date: Date?

    public init(name: String, date: Date?) {
        self.name = name
        self.date = date
    }
}

/// How the tmutil probe ended. Non-succeeded states carry an empty
/// snapshot list - a timed-out probe never fabricates rows.
public enum SnapshotProbeStatus: String, Sendable, Equatable {
    /// tmutil ran and its output was parsed.
    case succeeded
    /// The command exceeded the timeout; nothing was read.
    case timedOut
    /// /usr/bin/tmutil is missing (unusual environment).
    case unavailable
    /// tmutil ran but exited nonzero, or the scan was cancelled.
    case failed
}

/// The report the Apps/Disk tab shows: existence and count, never more.
public struct LocalSnapshotReport: Sendable, Equatable {
    public let status: SnapshotProbeStatus
    public let snapshots: [LocalSnapshot]
    /// Human-readable detail for non-success statuses (the "unavailable"
    /// line the UI renders).
    public let detail: String?

    public var count: Int { snapshots.count }

    public init(status: SnapshotProbeStatus, snapshots: [LocalSnapshot], detail: String?) {
        self.status = status
        self.snapshots = snapshots
        self.detail = detail
    }
}

/// Result handed from a lister to the report builder. Raw stdout stays
/// here so parsing is a pure function of a string (testable without
/// spawning Process).
public struct SnapshotListingResult: Sendable, Equatable {
    public let status: SnapshotProbeStatus
    public let output: String
    public let detail: String?

    public init(status: SnapshotProbeStatus, output: String, detail: String?) {
        self.status = status
        self.output = output
        self.detail = detail
    }
}

// MARK: Lister

/// Seam that makes the probe fakeable. Tests inject a canned result so no
/// tmutil process runs in the test suite.
public protocol SnapshotListing: Sendable {
    func listLocalSnapshots() async -> SnapshotListingResult
}

/// Default lister: absolute-path Process with a timeout, per the porting
/// contract (a command is only used when there is no native API, and then
/// with an absolute binary path plus a hard deadline).
public struct TMUtilSnapshotLister: SnapshotListing {
    public static let binaryPath = "/usr/bin/tmutil"
    /// Snapshots are always listed for the boot volume's APFS container.
    public static let mountPoint = "/"
    /// Mole's MOLE_TIMEOUT_SHORT_QUERY_SEC (lib/core/timeouts.sh:62).
    public static let timeoutSeconds: Int64 = 3

    public init() {}

    public func listLocalSnapshots() async -> SnapshotListingResult {
        let result = await BoundedProcessRunner.run(
            executablePath: Self.binaryPath,
            arguments: ["listlocalsnapshots", Self.mountPoint],
            timeout: TimeInterval(Self.timeoutSeconds)
        )
        guard let status = result.terminationStatus else {
            return SnapshotListingResult(
                status: .unavailable,
                output: "",
                detail: "tmutil could not be launched"
            )
        }
        // SIGTERM (15) / SIGKILL (9) means the watchdog fired: the command
        // hung past Mole's short-query budget and was killed.
        guard status == 0 else {
            let detail = (status == 15 || status == 9)
                ? "tmutil timed out after \(Self.timeoutSeconds)s"
                : "tmutil exited with status \(status)\(result.stderr.isEmpty ? "" : ": \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")"
            return SnapshotListingResult(
                status: (status == 15 || status == 9) ? .timedOut : .failed,
                output: result.stdout,
                detail: detail
            )
        }
        return SnapshotListingResult(status: .succeeded, output: result.stdout, detail: nil)
    }
}

// MARK: Service

/// The service the Apps/Disk tab calls. Read-only by design: it lists and
/// counts local snapshots, never deletes or thins them.
public struct TimeMachineSnapshots: Sendable {
    public let lister: any SnapshotListing

    public init(lister: any SnapshotListing = TMUtilSnapshotLister()) {
        self.lister = lister
    }

    public func list() async -> LocalSnapshotReport {
        let result = await lister.listLocalSnapshots()
        guard result.status == .succeeded else {
            return LocalSnapshotReport(status: result.status, snapshots: [], detail: result.detail)
        }
        let snapshots = Self.parseSnapshotNames(from: result.output)
        return LocalSnapshotReport(status: .succeeded, snapshots: snapshots, detail: nil)
    }

    /// Matches Mole's count regex
    /// `com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}`
    /// (lib/clean/system.sh:1473). Any other line (headers, notices) is
    /// ignored, so unexpected tmutil output yields zero rows instead of
    /// guessed ones.
    static func parseSnapshotNames(from output: String) -> [LocalSnapshot] {
        let pattern = #"com\.apple\.TimeMachine\.(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})(?:\.local)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(output.startIndex..., in: output)
        var snapshots: [LocalSnapshot] = []
        for match in regex.matches(in: output, range: fullRange) {
            func group(_ index: Int) -> Int? {
                guard index < match.numberOfRanges else { return nil }
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: output) else {
                    return nil
                }
                return Int(output[swiftRange])
            }
            guard let year = group(1), let month = group(2), let day = group(3),
                  let hour = group(4), let minute = group(5), let second = group(6),
                  let nameRange = Range(match.range, in: output) else { continue }
            let name = String(output[nameRange])
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            // The stamp is local time, so a local calendar interprets it
            // the same way tmutil printed it.
            let date = Calendar(identifier: .gregorian).date(from: components)
            snapshots.append(LocalSnapshot(name: name, date: date))
        }
        return snapshots
    }
}

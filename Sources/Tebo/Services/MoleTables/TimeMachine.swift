import Foundation

// MARK: - Time Machine table
// Ported from tw93/Mole lib/clean/system.sh (GPL-3.0),
// `clean_local_snapshots` and `clean_time_machine_failed_backups`. Data only —
// no disk access. Both rows are report-only: snapshots are listed for review
// upstream (`tmutil listlocalsnapshots /`, system.sh:1466) and failed backups
// are deleted through tmutil with a 48-hour safety window, which Tebo
// deliberately does not perform itself.

public enum TimeMachine {

    public static let all: [CleanTarget] = [
        CleanTarget(
            label: "Time Machine local snapshots",
            group: .timeMachine,
            path: .absolute("/"),
            kind: .directorySweep,
            risk: .review,
            needsAdmin: true,
            explanation: "Local APFS snapshots (com.apple.TimeMachine.*). Upstream only reports the count and suggests reviewing with `tmutil listlocalsnapshots /` — deleting snapshots is the user's call via Time Machine, and thinning needs admin. Report-only.",
            reportOnly: true,
            source: "mole lib/clean/system.sh:1466"
        ),
        CleanTarget(
            label: "Incomplete Time Machine backups",
            group: .timeMachine,
            path: .absolute("/Volumes"),
            kind: .findRule(maxDepth: 5, minAgeMinutes: 48 * 60, filesOnly: false),
            risk: .review,
            needsAdmin: true,
            explanation: "*.inProgress/*.inprogress dirs on backup volumes (Backups.backupdb and mounted .backupbundle/.sparsebundle), older than the 48-hour safety window (MOLE_TM_BACKUP_SAFE_HOURS). Upstream deletes them via tmutil; Tebo only reports them, since they are backup data on external volumes.",
            reportOnly: true,
            source: "mole lib/clean/system.sh:1100"
        ),
    ]
}

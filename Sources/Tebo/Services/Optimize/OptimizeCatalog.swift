import Darwin
import Foundation

// MARK: - OptimizeCatalog
// The runnable subset of Mole's optimize catalog (mole-src lib/optimize/catalog.sh:31-90), typed
// and grouped for the Health tab. Every task is safe to execute by the OptimizeRunner:
//   * nothing deletes user files — file removal belongs exclusively to DeletePipeline;
//   * nothing touches the live PowerLog database (Mole AGENTS.md hard rule);
//   * no shell, no sudo, absolute binary paths only;
//   * admin-gated tasks are catalogued so the UI can show the exact self-service command, but the
//     runner refuses to execute them unless the app already runs as root.
// Tasks from Mole's catalog that could not meet those rules (deletes, DB surgery, multi-step
// conditional logic, SIGKILL-uninterruptible kernel I/O) are deliberately not ported; see the
// list at the bottom of this file.

public enum OptimizeCatalog {

    // MARK: - Catalog

    /// All ported tasks, in Mole's catalog order (catalog.sh registration order).
    public static let all: [OptimizeTask] = [
        // catalog.sh:31-33 — system_maintenance, opt_system_maintenance (tasks.sh:172-200).
        // Admin: dscacheutil -flushcache and killall -HUP mDNSResponder are what Mole runs
        // under `sudo`; mdutil -s / is a read-only Spotlight verification.
        OptimizeTask(
            id: "system_maintenance",
            title: "DNS & Spotlight Check",
            explanation: "Flushes the DNS cache, restarts mDNSResponder and verifies the "
                + "Spotlight index status. Needs admin because the DNS cache is system-owned.",
            group: "Network",
            steps: [
                OptimizeCommandStep(executable: "/usr/sbin/dscacheutil", arguments: ["-flushcache"]),
                OptimizeCommandStep(executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"]),
                OptimizeCommandStep(executable: "/usr/bin/mdutil", arguments: ["-s", "/"]),
            ],
            needsAdmin: true,
            risk: .low,
            citation: "mole-src lib/optimize/catalog.sh:31-33, lib/optimize/tasks.sh:172-200"
        ),
        // catalog.sh:34-36 — cache_refresh, opt_cache_refresh (tasks.sh:203-303).
        // Mole also deletes the on-disk thumbnail cache folders here; Tebo runs only the
        // built-in qlmanage resets, because deleting files belongs exclusively to DeletePipeline.
        OptimizeTask(
            id: "cache_refresh",
            title: "Finder Cache Refresh",
            explanation: "Resets the QuickLook thumbnail cache and the icon services cache via "
                + "qlmanage, so Finder previews and app icons rebuild from current files. "
                + "Caches are automatically regenerated on demand.",
            group: "Finder",
            steps: [
                OptimizeCommandStep(executable: "/usr/bin/qlmanage", arguments: ["-r", "cache"]),
                OptimizeCommandStep(executable: "/usr/bin/qlmanage", arguments: ["-r"]),
            ],
            needsAdmin: false,
            risk: .low,
            citation: "mole-src lib/optimize/catalog.sh:34-36, lib/optimize/tasks.sh:203-303"
        ),
        // catalog.sh:43-45 — network_optimization, opt_network_optimization (tasks.sh:418-447).
        OptimizeTask(
            id: "network_optimization",
            title: "Network Cache Refresh",
            explanation: "Flushes the DNS cache and restarts mDNSResponder to fix stale DNS "
                + "results and resolve connectivity issues. Needs admin; the DNS cache rebuilds "
                + "automatically after the flush.",
            group: "Network",
            steps: [
                OptimizeCommandStep(executable: "/usr/sbin/dscacheutil", arguments: ["-flushcache"]),
                OptimizeCommandStep(executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"]),
            ],
            needsAdmin: true,
            risk: .low,
            citation: "mole-src lib/optimize/catalog.sh:43-45, lib/optimize/tasks.sh:418-447"
        ),
        // catalog.sh:49-51 — prevent_network_dsstore, opt_prevent_network_dsstore
        // (tasks.sh:1046-1086). Idempotent writes; reversible via
        // `defaults delete com.apple.desktopservices DSDontWrite{Network,USB}Stores`.
        OptimizeTask(
            id: "prevent_network_dsstore",
            title: "Prevent Finder .DS_Store",
            explanation: "Sets two persistent Finder preferences so macOS stops creating "
                + ".DS_Store files on network shares (SMB/AFP/NFS) and removable USB volumes. "
                + "Runs without admin and is reversible with defaults delete.",
            group: "Finder",
            steps: [
                OptimizeCommandStep(
                    executable: "/usr/bin/defaults",
                    arguments: ["write", "com.apple.desktopservices", "DSDontWriteNetworkStores", "-bool", "true"]
                ),
                OptimizeCommandStep(
                    executable: "/usr/bin/defaults",
                    arguments: ["write", "com.apple.desktopservices", "DSDontWriteUSBStores", "-bool", "true"]
                ),
            ],
            needsAdmin: false,
            risk: .low,
            citation: "mole-src lib/optimize/catalog.sh:49-51, lib/optimize/tasks.sh:1046-1086"
        ),
        // catalog.sh:55-57 — network_stack_optimize, opt_network_stack_optimize (tasks.sh:705-807).
        // Mole first probes for an active VPN and skips the flush when one is detected; that
        // probe is not ported to v1.0, so the explanation tells the user to close any VPN first.
        OptimizeTask(
            id: "network_stack_optimize",
            title: "Network Stack Refresh",
            explanation: "Flushes the routing table and clears the ARP cache to resolve network "
                + "issues. Needs admin. Mole skips this automatically when a VPN is active; v1.0 "
                + "does not probe for VPNs, so quit any VPN client before running it yourself.",
            group: "Network",
            steps: [
                OptimizeCommandStep(executable: "/sbin/route", arguments: ["-n", "flush"]),
                OptimizeCommandStep(executable: "/usr/sbin/arp", arguments: ["-a", "-d"]),
            ],
            needsAdmin: true,
            risk: .low,
            citation: "mole-src lib/optimize/catalog.sh:55-57, lib/optimize/tasks.sh:705-807"
        ),
        // catalog.sh:59-61 — disk_permissions_repair, opt_disk_permissions_repair
        // (tasks.sh:810-861). Mole checks needs_permissions_repair before escalating; v1.0 exposes
        // the repair command itself. The uid is the current user's uid, exactly as Mole computes
        // it with `id -u` before sudo. Rated medium because it rewrites ownership.
        OptimizeTask(
            id: "disk_permissions_repair",
            title: "Permission Repair",
            explanation: "Repairs ownership and permissions on the current user's home directory "
                + "via diskutil resetUserPermissions. Needs admin. Mole first detects whether a "
                + "repair is actually needed; v1.0 runs the command directly, so use it only when "
                + "file-access problems appear.",
            group: "System",
            steps: [
                OptimizeCommandStep(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["resetUserPermissions", "/", String(getuid())]
                ),
            ],
            needsAdmin: true,
            risk: .medium,
            citation: "mole-src lib/optimize/catalog.sh:59-61, lib/optimize/tasks.sh:810-861"
        ),
        // catalog.sh:61-63 — spotlight_index_optimize, opt_spotlight_index_optimize
        // (tasks.sh:864-962). Mole only rebuilds after mdfind speed probes prove search is slow;
        // the probes are not ported to v1.0, so the rebuild command is exposed directly.
        OptimizeTask(
            id: "spotlight_index_optimize",
            title: "Spotlight Optimization",
            explanation: "Rebuilds the Spotlight index with mdutil -E /. Needs admin. Mole only "
                + "offers this when speed probes show search is slow; the rebuild can take 1-2 "
                + "hours and finishes in the background.",
            group: "System",
            steps: [
                OptimizeCommandStep(executable: "/usr/bin/mdutil", arguments: ["-E", "/"]),
            ],
            needsAdmin: true,
            risk: .low,
            citation: "mole-src lib/optimize/catalog.sh:61-63, lib/optimize/tasks.sh:864-962"
        ),
        // catalog.sh:67-69 — periodic_maintenance, opt_periodic_maintenance (tasks.sh:1241-1289).
        // The periodic binary no longer ships with macOS 26+, which the live availability flag
        // reports as unavailable — the same UNAVAILABLE outcome Mole emits on those systems.
        OptimizeTask(
            id: "periodic_maintenance",
            title: "Periodic Maintenance",
            explanation: "Runs the macOS daily, weekly and monthly maintenance scripts (log "
                + "rotation, locate database and friends). Needs admin. On macOS 26+ the periodic "
                + "binary is gone and this task reports itself as unavailable.",
            group: "Maintenance",
            steps: [
                OptimizeCommandStep(
                    executable: "/usr/sbin/periodic",
                    arguments: ["daily", "weekly", "monthly"]
                ),
            ],
            needsAdmin: true,
            risk: .low,
            citation: "mole-src lib/optimize/catalog.sh:67-69, lib/optimize/tasks.sh:1241-1289"
        ),
    ]

    // MARK: - Query API (used by the Health tab)

    /// The task with this action id, if the catalog has one.
    public static func task(id: String) -> OptimizeTask? {
        all.first { $0.id == id }
    }

    /// Live availability: every binary in every step exists and is executable right now.
    /// Missing binaries are reported up front so the runner never has to attempt them
    /// (mirrors Mole's UNAVAILABLE outcome, outcomes.sh:14).
    public static func isAvailable(
        _ task: OptimizeTask,
        fileManager: FileManager = .default
    ) -> Bool {
        guard !task.steps.isEmpty else { return false }
        return task.steps.allSatisfy { step in
            fileManager.isExecutableFile(atPath: step.executable)
        }
    }

    /// All tasks grouped for display, in catalog order, each with a live available flag.
    /// The admin flag is `task.needsAdmin` on the returned listings.
    public static func groups(fileManager: FileManager = .default) -> [OptimizeTaskGroup] {
        var order: [String] = []
        var byGroup: [String: [OptimizeTaskListing]] = [:]
        for task in all {
            if byGroup[task.group] == nil {
                order.append(task.group)
                byGroup[task.group] = []
            }
            byGroup[task.group]?.append(
                OptimizeTaskListing(
                    task: task,
                    isAvailable: isAvailable(task, fileManager: fileManager)
                )
            )
        }
        return order.map { name in
            OptimizeTaskGroup(name: name, items: byGroup[name] ?? [])
        }
    }
}

// MARK: - Deliberately not ported from Mole's catalog (v1.0)
// catalog.sh rows skipped, with the reason:
//   saved_state_cleanup (37-39):      deletes .savedState folders — file deletion belongs
//                                     exclusively to DeletePipeline.
//   fix_broken_configs (40-42):       removes corrupted plist files — deletes user files.
//   sqlite_vacuum (46-48):            rewrites Mail/Safari/Messages databases; needs per-DB
//                                     integrity checks, running-app probes and a backup-first
//                                     policy that v1.0 does not have.
//   legacy_overrides_audit (52-54):   read-then-delete only when overrides exist; blindly
//                                     deleting absent keys would fail every healthy machine.
//   spotlight_orphan_rules_cleanup (64-66): per-entry logic (PlistBuddy read loop, bundle-id
//                                     resolution, filtered rewrite) — not a fixed command list.
//   disk_verify (73-75):              disabled by default upstream because verifyVolume triggers
//                                     kernel I/O that SIGKILL cannot interrupt — incompatible
//                                     with the runner's hard-timeout kill guarantee.
//   login_items_audit (76-78):        needs AppleScript automation (System Events) with
//                                     permission prompts plus multi-probe resolution logic.
//   quarantine_cleanup (79-81):       deletes rows in a live system database; DB tasks need the
//                                     backup/integrity-check infrastructure planned for later.
//   launch_agents_cleanup (82-84):    report-only audit over every plist (PlistBuddy loop with
//                                     conditional logic) — not a fixed command list.
//   notification_cleanup (85-87):     deletes rows in the live Notification Center database;
//                                     same backup/integrity gap as quarantine_cleanup.
//   coreduet_cleanup (88-90):         deletes WAL/SHM files and rows in a locked system database
//                                     — violates the no-file-deletion and no-live-DB rules.

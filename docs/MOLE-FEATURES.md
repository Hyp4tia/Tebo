# Mole workflows in Tebo

The File cleanup workspace follows the core workflows documented by the official
[Mole project](https://github.com/tw93/Mole#features-in-detail). The implementation
was checked against upstream revision
[49475f1d5cf82243530ef64c0d64da2cbfcebecd](https://github.com/tw93/Mole/tree/49475f1d5cf82243530ef64c0d64da2cbfcebecd)
on 2026-10-11. Tebo runs its native Swift services, not Mole's shell scripts.

## Conservative safety policy in the current source

The Mole-only hardening deliberately reduces cleanup coverage. The installed/public
1.2 app does not contain this hardening. The
[rule disposition manifest](MOLE-RULE-DISPOSITIONS.json) accounts for every original
table entry and is checked against the real runtime registry by
`MoleRuleManifestTests`. Port citations and row counts are not a certification of
full upstream behavior.

- Two Chrome profile cache rules have explicit rebuildable-cache eligibility.
  Recommendations also require a safe risk label, known inactive process-name and
  executable-path evidence, a complete local safety walk and an idle open-file probe.
- Five scoped rules require manual review: regular Group Container cache/log
  leaves, stale numbered NeatDM segments, and three keep-newest developer-symbol
  families. Neither age nor the manual label proves that the content is unwanted.
- The other 462 rules remain read-only, including broad cache/state sweeps,
  service-worker/offline stores, firmware and signed app-bundle internals.
  Administrator rules never gain removal authority.
- Saved state, malformed preferences, installers and orphan caches are never
  automatically recommended. Project artifact removal remains read-only without
  a supported rebuildability contract. Related uninstall data stays read-only;
  explicit app-bundle removal is a separate reviewed action.
- Unknown protection, process, owner, activity, cloud/locality or traversal evidence
  keeps an item. Current protections, source eligibility, reviewed path/revision and
  physical-parent evidence are checked again at the Trash boundary.

These are conservative contracts, not universal zero-risk guarantees. Pathname-based
Trash operations retain a small non-atomic interval after validation. Logical bytes
moved to Trash are not measured free disk space. No Media/Krokiet hardening is
included in this change.

| Workflow | What works in Tebo | Implementation |
| --- | --- | --- |
| Clean | Known cleanup tables, caches/logs, orphaned app data, downloaded installers, standard/custom installer locations, kept-item explanations and protected paths | `TargetScanner`, `OrphanScanner`, `InstallerFinder`, `CleanResultCombiner`, `CleanView` |
| Uninstall | Installed-app inventory, explicit app-bundle review/removal, related-data read-only review, shared-copy/running/system protection, confirmed Trash moves | `ApplicationUninstaller`, `UninstallView` |
| Optimize | Command previews, Finder cache refresh, persistent Finder preferences, Spotlight/login-item audits, old saved-state and invalid-preference review, database compaction with private backup | `OptimizeCatalog`, `OptimizeRunner`, `MaintenanceScanner`, `DatabaseMaintenance` |
| Analyze | Native folder measurements, drill-down, usage bars, protected read-only entries, explicit partial/unavailable sizes, reviewed Trash moves | `NativeDiskAnalyzer`, `NativeAnalyzeView` |
| Status | Live CPU/per-core activity, memory, disk/network counters, battery, uptime and processes, refreshed while visible | `LiveSystemStatus`, `MoleStatusView` |
| Project Cleanup (Mole Purge) | Project grouping, chosen/persisted roots, recent-activity defaults, repository/tracked-file/credential guards at discovery and removal | `ProjectArtifactScanner`, `MolePurgeView` |
| Installers within Clean | Payload-aware finder, standard/custom roots, installer formats, ZIP payload checks and manual-review source labels; no separate sidebar entry | `InstallerFinder`, `CleanResultCombiner`, `CleanView` |
| History / Settings | Actual operation-log tail and search, Preview and user-protected paths/action names | `OperationLog`, `OperationHistoryView`, `SettingsView` |

## Boundaries

The user requested installer cleanup be grouped under Clean on 2026-10-11.
Clean shows these files in a Downloaded Installers category for manual review.
Old timestamps alone never produce an automatic recommendation.
Paths already offered by another cleanup scanner, including installers inside an
offered cache folder, are not counted twice. Ordinary ZIP archives are kept.
Project Cleanup discovers developer artifacts for read-only review. A name such as
`node_modules`, `.build` or `dist` does not prove rebuildability; generic unique
exports and unsupported artifact kinds stay kept.

This is Tebo's native adaptation of the core workflows, not an assertion of full
CLI or proprietary Mole for Mac parity. Installer/saved-state scans have bounded
scope. App-data matching uses exact bundle IDs and owned launch-agent evidence;
ambiguous names, shared group containers, protected system data, and unreadable
items are kept. App bundles and related files move to Trash rather than being
permanently deleted. Tebo never empties Trash automatically.

Administrator maintenance stays manual. Tebo does not request administrator
credentials, alter Touch ID, install scheduled jobs, or change Mole's installation.
Destructive database-history clearing and global/system cleanup remain outside
Tebo's existing safety policy. Supported database optimization compacts unused
pages while preserving records, with integrity checks and SQLite backups first.

Analyze and Status use no czkawka operations. The image workspace keeps its
existing engine-backed tools. Network status reads local counters; it makes no
network requests. Status refresh stops when its screen is left.

All scan measurements are observations, not atomic filesystem snapshots.
Incomplete sizes use ≥; unknown values are labeled. Preview is on by default,
removal requires confirmation, and reviewed identities are checked again at the
existing deletion pipeline.

The 2026-10-12 functional audit corrected browser-profile wildcard expansion,
partial Clean sizes, recent artifact activity and overlapping running-app scopes.
Running-app guards also run at removal. Whole user-data roots and credential
trees are read-only; absolute protected children keep their parents, with physical
whitelist aliases checked at the deletion boundary. See
[the audit record](../.hermes/plans/2026-10-12_file-cleanup-audit.md) for evidence
and the remaining live-check limitation.

Live UI audit follow-up: Clean installer locations and Project Cleanup roots
invalidate cached rows, advisories, file identities and selection when changed.
Obsolete scan requests are cancelled. Analyze keeps its current folder/report
across navigation and invalidates the report when that folder changes. Evidence
is in [.hermes/plans/2026-10-12_file-cleanup-audit.md](../.hermes/plans/2026-10-12_file-cleanup-audit.md).

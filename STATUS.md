# Status

## Current work

[External release preparation](.hermes/plans/2026-10-14_release-preparation.md)
has a verified, notarized 1.2/build 3 app and DMG, signed GitHub appcast, portable
video helpers and source companions. The updater passed actual installation and
corruption-rejection checks. Full Disk Access was refreshed for the signed app;
Clean, Trash recovery, large scans and live blur checks passed. The full gate passed
217 tests in 32 suites. [The public verification record](docs/RELEASE-1.2-QA.md)
owns detailed measurements and limits. The source is pushed to `main` and
[v1.2](https://github.com/Hyp4tia/Tebo/releases/tag/v1.2) is published as the latest
stable release with the DMG, signed appcast, checksums and both source companions.
Public downloads match the verified artifacts, and the installed app's live
GitHub update check reports that 1.2 is current. The final signed installation is
`/Applications/Tebo.app`; 35 duplicate build/test bundles were moved to recoverable
Trash. LaunchServices and Spotlight now identify one installed Tebo. App Store
remains deferred.

The live background-blur fix is complete. Settings and the main background now
share one observable appearance state. Native checks confirmed slider changes in
both workspaces with Settings open, an actual slider drag and relaunch persistence.
Verification restored the original blur value.
The [appearance task](.hermes/plans/2026-10-12_skeuomorphic-preview.md) owns the
reproduction, correction and verification evidence.

[Media cleanup / Krokiet integration](.hermes/plans/2026-10-12_krokiet-media-workspace.md)
is complete, including native scan, selection, layout and copy-export checks on
disposable fixtures. The final gate passed 214 tests in 31 suites; the native
build, signature check and bundled self-test passed. Rename checkpoint `b052fad`
and integration `effc8d7` were pushed to `origin/redesign`, with messages ending
in `-Codex`. Original files and the app icon are unchanged. Initial scan settings,
Preview and blur were restored and verified after relaunch. The rebuilt app
includes the completed Media cleanup workspace; no active integration blocker remains.
[The feature map](docs/MEDIA-FEATURES.md) owns tool coverage, export behavior and
version-specific boundaries.

The Mole-only File cleanup workspace and its missing native services are
implemented. See [the feature map](docs/MOLE-FEATURES.md) for supported behavior
and boundaries, [DESIGN.md](DESIGN.md) for visual guidance, and
[the feature task record](.hermes/plans/2026-10-11_mole-file-workspace.md) for validation.

The cleanup UI follow-up is also complete: shared stat cards have equal heights,
installers are included in Clean, and Purge is labeled Project Cleanup. Scrolling
was already resolved and remains unchanged. See
[the polish task record](.hermes/plans/2026-10-11_cleanup-ui-polish.md).

Core screens: Clean, Uninstall, Optimize, Analyze, Status and Project Cleanup,
plus History and protection settings. Image navigation and its engine workflows
are preserved. Preview remains on by default; confirmed removals use Trash.

## Latest completion

The approved [silver/tactile UI](.hermes/plans/2026-10-12_skeuomorphic-preview.md)
is included in the final app. Artwork fills the background behind the
full-size workspace. Settings blur updates live and persists across relaunch.
The original icon remains unchanged after the user withdrew its replacement.

[The File cleanup audit](.hermes/plans/2026-10-12_file-cleanup-audit.md) found and
corrected measurement, profile-glob, running-app, artifact-activity, user-root
and whitelist issues. Live folder testing also exposed stale results after a
location change; cached scans now track their chosen folders and cancel obsolete
requests. A pending Clean scan also exposed filesystem reads during broad glob
expansion; protected branches are now excluded before traversal. The final build,
signature check, 202 tests and bundled self-test passed. The user requested a rename to Media cleanup and a checkpoint commit/push on
`redesign`, followed by Krokiet integration. See [the current task](.hermes/plans/2026-10-12_krokiet-media-workspace.md).

The final native audit passed: minimum-window layout, Clean scan/search/selection,
Uninstall protection/preview, maintenance preview, Analyze measurements and
navigation, Project Cleanup safeguards and folder changes, Status, History and
workspace switching. Clean completed in 10.4 seconds with 118 real results.
The blur control works live and persists; prior settings and scan locations were
restored. The rebuilt app is open on its File cleanup overview.

No personal files were moved. Full Disk Access remained off, so protected system
locations were not fully covered by live checks. The audit record owns detailed
results and limitations; no active blocker remains.

## Earlier records

[Reference frontend](.hermes/plans/2026-10-11_tebo-reference-ui.md),
[v1.1 plan](.hermes/plans/2026-09-25_tebo-v1.1-ui.md),
[v1.0 plan](.hermes/plans/2026-09-24_tebo-v1.0-launch.md), and
[historical audit](docs/AUDIT.md) retain their own dated evidence.

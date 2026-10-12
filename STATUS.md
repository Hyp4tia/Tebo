# Status

## Current work

[Media cleanup / Krokiet integration](.hermes/plans/2026-10-12_krokiet-media-workspace.md)
is in progress. The workspace rename is implemented; the requested checkpoint
commit/push precedes new integration code.


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
is built in the workspace `Tebo.app`. Artwork fills the background behind the
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

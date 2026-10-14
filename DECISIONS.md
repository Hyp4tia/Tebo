# Decisions

## YUM-SETUP-001: additive foundation, existing work retained

Date: 2026-10-11. Source: the user's invocation of the Yummy skill and its
create-only setup boundary.

Context: Tebo already has a README, application structure, working conventions,
release location, and plans. Root foundation documents were absent.

Choice: create only missing foundation paths, use the universal project-local
skill destination `.agents/skills/yummy/`, retain `.hermes/plans/` as the existing
work system, and reuse `Resources/` for supporting inputs. Add empty `inbox/`,
`areas/`, `work/`, `outputs/`, and `archive/` for future authorized material.

Rationale: give future work a reading order and explicit evidence ownership
without moving or changing existing project material.

Consequences: `work/TASK-TEMPLATE.md` is reusable but no task is queued; release
artifacts remain in `dist/`. No area-specific rules are needed during setup.

## Existing choices

Historical architecture and delivery choices remain in the
[v1.0 plan](.hermes/plans/2026-09-24_tebo-v1.0-launch.md),
[v1.1 plan](.hermes/plans/2026-09-25_tebo-v1.1-ui.md), and
[working conventions](.hermes.md). Refer to their context and source evidence
rather than treating old proposals as new confirmed decisions here.

## UI-001: supplied reference and logo govern the frontend

Date: 2026-10-11. Source: the user's request to follow the attached design as
closely as possible, use the supplied logo, add File cleanup / image cleanup,
and keep scope to the frontend plus existing functionality.

Choice: replace the top-navigation shell with the reference's sidebar, central
overview/tool workspace, and brand/activity inspector. Use the supplied raster
logo for both UI sizes and the macOS app icon. Keep measured results truthful
rather than copying the reference's numeric examples. Reuse existing tool screens
and services; missing features show unavailable states.

Consequences: this direction supersedes the old top-pill shell guidance. Visual
details live in [DESIGN.md](DESIGN.md); verification and deliverables live in the
[UI task record](.hermes/plans/2026-10-11_tebo-reference-ui.md).

## MOLE-001: native Mole workflows in File cleanup

Date: 2026-10-11. Source: the user's request for Mole's actual File cleanup
features and explicit choice to implement missing functionality too.

Choice: expose Clean, Uninstall, Optimize, Analyze, Status, Purge and Installers,
with History and protection settings. Fill the missing native services while
preserving the reference shell, Preview, Trash-only removal, whitelist and
no-privilege-escalation policy. Keep image-workspace navigation and engine tools.

Rationale: the earlier generic categories mixed cleanup systems and did not
expose Mole's actual workflows. Native services avoid adding another shell engine
and let reviewed identities, partial measurements and app-ownership safeguards
remain explicit.

Consequences: this scope supersedes the earlier frontend-only boundary for this
feature update. Administrator tasks remain manual, and this is a native adaptation
of the core workflows rather than full CLI/proprietary-app parity. See
[the feature map](docs/MOLE-FEATURES.md) and
[task record](.hermes/plans/2026-10-11_mole-file-workspace.md).

## MOLE-002: group installers under Clean and clarify Purge

Date: 2026-10-11. Source: the user's cleanup UI feedback asking whether Installers
belongs in Clean, asking what Purge means, and reporting uneven stat cards.

Choice: include installer discovery in the Clean scan and remove its separate
sidebar/overview entry. Preserve selectable installer locations and conservative
age recommendations. Rename Purge to Project Cleanup, with explanatory copy
about rebuildable build outputs and downloaded dependencies. Give shared stat
cards one height regardless of optional detail text.

Consequences: this supersedes MOLE-001's separate Installers navigation and Purge
label. The underlying native capabilities and protection checks are retained.
The user subsequently said scrolling was resolved; scrolling changes are outside
this follow-up. See [DESIGN.md](DESIGN.md) and
[the polish task record](.hermes/plans/2026-10-11_cleanup-ui-polish.md).

## UI-002: approved silver layout, tactile controls and adjustable backdrop

Date: 2026-10-12. Source: the user selected the frosted-silver image, requested
skeuomorphic buttons and the supplied artwork, approved the preview with "go ahead",
and clarified that the artwork is a blurred background with a Settings slider.

Choice: keep the full-size three-column workspace, use neutral graphite/pearl
button faces, and render the artwork behind the window's content. Only the artwork
receives the saved blur value; controls remain sharp. Keep current window dimensions,
real scanner data and workflows. The later icon replacement request was withdrawn;
the original logo and ICNS remain unchanged.

Consequences: this refines UI-001's original palette and depth. It does not adopt
the alternative Mole top-navigation concepts. See [DESIGN.md](DESIGN.md) and
[the implementation record](.hermes/plans/2026-10-12_skeuomorphic-preview.md).

2026-10-13 correction: use a single observable appearance model shared by the
main and Settings scenes. Separate AppStorage values updated the Settings preview
but failed to redraw the actual background in native reproduction. Keep the
existing persistence key and slider range; live changes use direct observation.

## MEDIA-001: native Krokiet workflows in Media cleanup

Date: 2026-10-12. Source: the user's rename request and instruction to create
Krokiet integration after committing the existing redesign checkpoint.

Choice: reuse the verified Czkawka core for all 14 tool families, expose native
scan controls and protected references, and group them into six pages within the
approved shell. EXIF cleanup and video transforms export new copies through
ImageIO and ffmpeg. Original rewrites and engine fix/delete flags stay excluded.

Rationale: Krokiet is a frontend for the core already bundled with Tebo. This
keeps one scanner contract, native navigation and the existing safety boundaries.
Name/extension corrections and invalid links remain review-only where original
mutation would conflict with those boundaries. See [the feature map](docs/MEDIA-FEATURES.md)
and [task record](.hermes/plans/2026-10-12_krokiet-media-workspace.md).

## RELEASE-001: full external edition first, signed GitHub updates

Date: 2026-10-14. Source: the user's request to prepare/sign Tebo and provide
GitHub-delivered updates, followed by "Full GitHub release first; defer App Store"
and the choice of version 1.2.

Choice: preserve the full File cleanup and Media cleanup edition for Developer ID
distribution. Embed Sparkle 2.10.0 with HTTPS, signed feeds and signed archives,
validation before extraction, optional automatic checks and no system profiling.
Keep both Apple and update-signing private keys in the local Keychain. Build
portable video helpers from pinned upstream snapshots; include their notices and
corresponding source alongside the app source. Require notarization and Gatekeeper
acceptance before creating a reviewable GitHub draft. Public publishing remains
a separate approval step.

Consequences: this supersedes the old absolute no-network constraint only for
GitHub update checks/downloads. Scanning and media processing remain local.
App Store sandboxing and submission are deferred. Builds without an updater need
one manual installation; later signed releases use the app updater.
[The release guide](docs/RELEASING.md) owns the repeatable workflow and
[the verification record](docs/RELEASE-1.2-QA.md) owns measured release checks.

2026-10-15 delivery: the user authorized publication and pushing the verified
release source to `main`. Version 1.2 is the latest stable GitHub release, and
`/Applications/Tebo.app` is the final local installation. Duplicate development,
verification and staging app bundles were moved to recoverable Trash so macOS
offers the final app. The release task and verification record own publication,
update-feed and installation evidence.

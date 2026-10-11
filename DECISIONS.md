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

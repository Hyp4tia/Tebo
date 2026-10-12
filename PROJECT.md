# Tebo

## Purpose and intended outcome

Tebo is a native macOS cleaner combining native Swift cleanup scanning with a
bundled czkawka CLI helper for file analysis. Its documented aim is a small,
installable app whose results come from real scans and whose removals can be
recovered from the Trash. Source: [README.md](README.md), opening and safety model.

## Scope

File cleanup covers Mole's Clean, Uninstall, Optimize, Analyze, Status and
Project Cleanup workflows. Downloaded installers are included in Clean; Project
Cleanup adapts Mole's Purge command. Media cleanup adapts Krokiet’s tool families through the verified Czkawka core,
with native comparison controls, file checks and copy exports.
[The media feature map](docs/MEDIA-FEATURES.md) owns its supported behavior and limits.
See [README.md](README.md#what-it-does) for each tab's scope instead of maintaining
another feature table here. App code lives in `Sources/Tebo/`; tests in `Tests/`;
helper notes in `Engines/`; assets and bundle configuration in `Resources/`.

## Constraints and success criteria

The repository documents macOS 14+ and Apple Silicon as its target, with SwiftUI
and a separate engine process. These are local project targets, not a newly
verified external hardware or platform compatibility claim.

The intended behavior is preview before removal, real measured results,
SafetyGate validation at removal time, recoverable Trash operations, verified
engine execution, no app network activity or telemetry, and no privilege
escalation. [README.md](README.md#safety-model) owns the documented safety model;
[.hermes.md](.hermes.md) owns its implementation guardrails. Future authorized
changes must establish their behavior using the applicable tests and real
verification described there. Setup does not establish current runtime compliance.

## Sources and navigation

- [README.md](README.md): user-facing overview and documented build/install workflow.
- [STATUS.md](STATUS.md): concise state and next action.
- [.hermes/plans/](.hermes/plans/): existing plans and their recorded delivery evidence.
- [docs/AUDIT.md](docs/AUDIT.md): historical audit measurements.
- [DESIGN.md](DESIGN.md): source-backed visual values and remaining gaps.
- [DECISIONS.md](DECISIONS.md): foundation setup choice and links to existing choices.

## Unknowns

The user's 2026-10-11 frontend request adopts the supplied visual reference and
logo, adds File cleanup / image cleanup workspaces, and limits changes to UI and
existing functionality. [DESIGN.md](DESIGN.md) owns that visual direction, and the
[UI task record](.hermes/plans/2026-10-11_tebo-reference-ui.md) owns execution evidence.
The subsequent Mole-workspace request explicitly authorized implementing missing
backend functionality. [docs/MOLE-FEATURES.md](docs/MOLE-FEATURES.md) records the
native feature map and boundaries. No next release target or schedule was specified.

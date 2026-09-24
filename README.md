# SuperClean 🧹

A native macOS cleaner: the file-analysis tools of [Krokiet/czkawka](https://github.com/qarmin/czkawka)
and the cleanup knowledge of [Mole](https://github.com/tw93/Mole), in one fast SwiftUI app.

Small on purpose: no daemons, no background agents, no telemetry, **no network access at all**.
Everything the app does is visible in a preview before it happens, and everything it removes goes to
the Trash.

Krokiet's Rust engine is not reimplemented: the MIT-licensed `czkawka_cli` binary is bundled as a
helper process and its JSON answers are parsed in Swift. Mole's shell tables are reimplemented
natively, so no shell script ever runs.

## Requirements

- macOS 14 or newer, Apple Silicon
- Full Disk Access (System Settings → Privacy & Security → Full Disk Access), needed to see other
  apps' caches and containers. The app walks you to it on first launch.

## Build and run

```sh
./scripts/fetch-engine.sh     # downloads + verifies the pinned czkawka_cli (arm64, MIT)
xcodegen generate             # regenerates SuperClean.xcodeproj from project.yml
open SuperClean.xcodeproj     # then press Cmd+R
```

Other entry points:

```sh
./scripts/verify.sh           # build + tests + headless self-test (the pre-commit gate)
swift test                    # logic tests only, no UI
./build-app.sh                # no-Xcode fallback: builds SuperClean.app and opens it
```

Why the `.xcodeproj` and not `Package.swift`? A Swift Package builds a raw binary with no bundle
identifier, which produces `linkd.autoShortcut` noise and no proper window. The project generated
from `project.yml` builds a real signed `SuperClean.app`. After changing files, re-run
`xcodegen generate`.

## What it does

| Tab | What it does | Status |
|---|---|---|
| Clean | Known-safe caches, logs and leftovers, grouped, biggest first | in progress |
| Duplicates | Exact duplicates by hash, grouped, keep-one workflow | planned (engine) |
| Apps | Inventory, uninstall plan with leftovers, shared-data guard | planned |
| Disk | Disk explorer with drill-down and largest files | planned |
| Health | Live CPU/memory/disk/process snapshot | partial |
| Toolbox | Purge, Installers, Fixers, History, Optimize | partial |

The honest version of that table lives in `.hermes/plans/2026-09-24_superclean-v1.0-launch.md`.
Nothing in this app invents results: if a scan finds nothing, it says so.

## Safety model

1. **Dry-run is on by default.** Scans preview; nothing moves until you turn it off.
2. **One delete path.** Every removal goes through `DeletePipeline`, which re-validates the path
   with `SafetyGate`, re-checks the file's identity, then uses `FileManager.trashItem`.
   No `rm`, ever.
3. **Path validation is ported from Mole**: no relative paths, no `..` traversal, no control
   characters, symlinks resolved (leaf and ancestors) before a decision, system locations refused.
4. **Your whitelist wins.** Entries live in `~/.config/superclean/whitelist` (one protected
   substring per line) and are applied before every scan and again before every delete.
5. **Everything is logged** to `~/Library/Logs/superclean/operations.log`.
6. **No privilege escalation beyond an explicit admin prompt**, only for a fixed, allow-listed set
   of system maintenance commands that each preview exactly what they will run.
7. **The engine is hash-pinned.** `czkawka_cli` is verified against a hard-coded SHA-256 before use;
   a tampered binary is refused, not run.

## Layout

```
Sources/SuperClean/
  SuperCleanApp.swift        # @main entry + Settings scene
  ContentView.swift          # tab shell + global dry-run switch
  Models/
    AppState.swift           # @Observable app state (dry-run, whitelist, engine status, results)
    ScanResult.swift         # one cleanable item (path + size + reason)
  Services/
    SafetyGate.swift         # Mole's path rules — every path must pass
    PathValidator.swift      # path-string validation (traversal, symlinks, critical list)
    DeletePipeline.swift     # the only place that calls trashItem
    ScanEngine.swift         # streaming scans with caps, progress, cancellation
    CleanerService.swift     # cleanup sweeps (Mole tables + purge + installers)
    MoleTables/              # Mole's knowledge as data, each row citing its source line
    CzkawkaBridge.swift      # runs czkawka_cli via Process, parses its JSON file
    EngineLocator.swift      # finds + hash-verifies the engine and ffmpeg
    OperationLog.swift       # ~/Library/Logs/superclean/operations.log
  Views/                     # Shared/ScanTab.swift powers most tabs
scripts/                     # fetch-engine.sh, verify.sh, release.sh, fixtures
Engines/README.md            # pinned engine version + digest
Resources/                   # Info.plist, NOTICE.md, whitelist.default
```

## License and credits

GPL-3.0 (`LICENSE`). `NOTICE.md` carries the full attribution:

- **czkawka_cli** by Rafał Mikrut (MIT) — bundled and hash-pinned. The `krokiet` frontend is
  GPL-3.0-only and is deliberately not shipped.
- **tw93/Mole** (GPL-3.0) — source of the cleanup path tables, protection rules and semantics that
  this app reimplements in Swift. SuperClean is an independent project: its own name and icon, no
  affiliation and no implied endorsement, as Mole's TRADEMARK.md requires.
- **ffmpeg** (optional, not bundled) — enables similar-video and video file checks when installed.

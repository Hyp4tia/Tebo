# Tebo 🧹

**Tebo** (Coptic: **ⲧⲉⲃⲟ**) means *to purify, to make pure*. It is the right name for a cleaner:
the app purifies a Mac by removing what is genuinely safe to remove, and by saying plainly what it
will not touch.

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

## Install a build

```sh
./scripts/release.sh          # -> dist/Tebo-<version>.dmg (signed, ready to hand out)
```

`release.sh` verifies the engine digest, builds Release, checks the bundle really contains the
icon/NOTICE/engine, signs with the best certificate it can find, and prints the DMG's SHA-256.
Open the DMG, drag the app to Applications, then **right-click → Open** once: the app is not
notarized, so macOS asks for that confirmation on first launch. The image carries the same
instructions as `First Launch.txt`.

Notarization removes that step and is one command away once a Developer ID certificate exists:

```sh
SIGN_IDENTITY="Developer ID Application: …" ./scripts/release.sh
./scripts/notarize.sh
```

`notarize.sh` refuses to run without a Developer ID signature and a stored `notarytool`
credential profile, and prints exactly how to create the profile if it is missing.

## Build and run

```sh
./scripts/fetch-engine.sh     # downloads + verifies the pinned czkawka_cli (arm64, MIT)
xcodegen generate             # regenerates Tebo.xcodeproj from project.yml
open Tebo.xcodeproj           # then press Cmd+R
```

Other entry points:

```sh
./scripts/verify.sh           # build + tests + headless self-test (the pre-commit gate)
swift test                    # logic tests only, no UI
./build-app.sh                # no-Xcode fallback: builds Tebo.app and opens it
```

Why the `.xcodeproj` and not `Package.swift`? A Swift Package builds a raw binary with no bundle
identifier, which produces `linkd.autoShortcut` noise and no proper window. The project generated
from `project.yml` builds a real signed `Tebo.app`. After changing files, re-run
`xcodegen generate`.

## What it does

| Tab | What it does | Status |
|---|---|---|
| Clean | Mole's ported path tables (469 rows across 10 groups), measured on this Mac, biggest first | working |
| Duplicates | Exact duplicates, similar images/music/video, empty folders/files, temp files, big files, via the bundled engine. Shows previews, with three layouts (rows, thumbnails side by side, closest pair per group) and a similarity threshold slider wired to the engine's own `-s` measure | working |
| Apps | Leftovers whose owning app is gone, grouped by the app they came from with the app's real icon when its bundle can still be found (including one still in the Trash) | working |
| Disk | Volume total/free, snapshot count, and the largest files under a folder you pick | working |
| Health | Live memory/cores/uptime plus Mole's maintenance catalog, admin tasks listed with the command to run yourself | working |
| Toolbox | Purge, Installers, Fixers (symlinks/broken/ext/names), History | working |

The development plan and the working notes are kept beside the checkout, not published here.
Nothing in this app invents results: if a scan finds nothing, it says so.

## Safety model

1. **Dry-run is on by default.** Scans preview; nothing moves until you turn it off.
2. **One delete path.** Every removal goes through `DeletePipeline`, which re-validates the path
   with `SafetyGate`, re-checks the file's identity, then uses `FileManager.trashItem`.
   No `rm`, ever.
3. **Path validation is ported from Mole**: no relative paths, no `..` traversal, no control
   characters, symlinks resolved (leaf and ancestors) before a decision, system locations refused.
   Protection is compared by inode, so a case-variant alias such as `/SYSTEM` is caught too.
4. **Your whitelist wins.** Entries live in `~/.config/tebo/whitelist` (one protected
   substring per line) and are applied before every scan and again before every delete.
5. **Everything is logged** to `~/Library/Logs/tebo/operations.log`.
6. **No privilege escalation.** Tasks that need root are listed with the exact command and a
   disabled Run button; the app never asks for an administrator password and never runs them.
7. **The engine is verified before it runs.** A developer checkout copy must match a hard-coded
   SHA-256; the copy inside the app must carry a valid signature sealed by the app bundle. A binary
   that matches neither is refused and reported in Settings, never executed.
8. **Cancelling a scan kills the child process.** Every child runs through one bounded runner that
   delivers exit through the process's termination handler, so a cancelled scan cannot wedge the app.

## Verification

```sh
swift test                                  # 144 tests, 20 suites
swift run -c release Tebo --benchmark=30    # footprint across 30 scans
Tebo.app/Contents/MacOS/Tebo --selftest      # what the running app resolved and how
```

`docs/AUDIT.md` records the measured facts: the memory numbers with their control run, every
`Process` call site with its absolute binary and its bound, zero network API usage in the sources,
the hardened runtime flag, and the engine parsers checked against real captured output. The captured
engine output itself lives in `Tests/Fixtures/czkawka/`, regenerated by
`scripts/capture-czkawka-fixtures.sh`.

## Layout

```
Sources/Tebo/
  TeboApp.swift              # @main entry, windows, headless --selftest / --benchmark
  ContentView.swift          # tab shell + global dry-run switch
  Models/
    AppState.swift           # @Observable app state (dry-run, whitelist, engine, results)
    ScanResult.swift         # one cleanable item (path + size + reason)
  Services/
    SafetyGate.swift         # Mole's path rules, every path must pass
    PathValidator.swift      # path-string validation (traversal, symlinks, critical list, inodes)
    DeletePipeline.swift     # the only place that calls trashItem
    BoundedProcessRunner.swift # the only place that spawns a child process
    TargetScanner.swift      # turns Mole's tables into real rows + read-only advisories
    CleanerService.swift     # directory sizing and sweeps
    MoleTables/              # Mole's knowledge as data, each row citing its source line
    CzkawkaBridge.swift      # runs czkawka_cli, reads its JSON file, streams items
    CzkawkaJSON/             # tool enum, item model, parsers verified against captures
    Optimize/                # Mole's maintenance catalog + runner (admin tasks never escalated)
    OrphanScanner.swift      # leftovers whose owning app is gone, conservative by design
    InstallerFinder.swift    # stray installers in the usual download locations
    TimeMachineSnapshots.swift # read-only snapshot listing
    StatusReport.swift       # disk, memory, uptime, CPU (nil when a value cannot be read)
    EngineLocator.swift      # finds + verifies the engine and ffmpeg
    OperationLog.swift       # ~/Library/Logs/tebo/operations.log
  Views/                     # Shared/ScanTab.swift powers most tabs
scripts/                     # fetch-engine.sh, verify.sh, release.sh, notarize.sh, fixtures
Engines/README.md            # pinned engine version + digest
Resources/                   # Info.plist, NOTICE.md, whitelist.default
```

## License and credits

GPL-3.0 (`LICENSE`). `NOTICE.md` carries the full attribution:

- **czkawka_cli** by Rafał Mikrut (MIT), bundled and hash-pinned. The `krokiet` frontend is
  GPL-3.0-only and is deliberately not shipped.
- **tw93/Mole** (GPL-3.0), source of the cleanup path tables, protection rules and semantics that
  this app reimplements in Swift. Tebo is an independent project: its own name and icon, no
  affiliation and no implied endorsement, as Mole's TRADEMARK.md requires.
- **ffmpeg** (optional, not bundled), enables similar-video and video file checks when installed.

The app was called SuperClean during development and was renamed to Tebo before its first release.

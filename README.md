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

## Install a build

```sh
./scripts/release.sh          # -> dist/SuperClean-<version>.dmg (signed, ready to hand out)
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
| Clean | Mole's ported path tables (469 rows across 10 groups), measured on this Mac, biggest first | working |
| Duplicates | Exact duplicates, similar images/music/video, empty folders/files, temp files, big files, via the bundled engine, with a keep-one-per-group action | working |
| Apps | Leftovers whose owning app is gone, plus every entry it kept and why | working |
| Disk | Volume total/free, snapshot count, and the largest files under a folder you pick | working |
| Health | Live memory/cores/uptime plus Mole's maintenance catalog, admin tasks listed with the command to run yourself | working |
| Toolbox | Purge, Installers, Fixers (symlinks/broken/ext/names), History | working |

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
7. **The engine is verified before it runs.** A developer checkout copy must match a hard-coded
   SHA-256; the copy inside the app must carry a valid signature sealed by the app bundle. A binary
   that matches neither is refused and reported in Settings, never executed.

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

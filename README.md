# SuperClean 🧹

Native macOS cleaner in Swift — **Krokiet (czkawka) + Mole** in one fast, light app.

> GPL-3.0. Engines: [qarmin/czkawka](https://github.com/qarmin/czkawka) (Rust) + [tw93/Mole](https://github.com/tw93/Mole) (Go/shell). This repo reuses their ideas Binaries/tables, not their UI.

## Open & Run (use the .xcodeproj for Cmd+R)
```sh
cd SuperClean
open SuperClean.xcodeproj  # ← double-click this, then press Cmd+R
swift test                 # logic tests only, no UI
./build-app.sh             # no-Xcode fallback: builds SuperClean.app + opens it
```
> Why not `Package.swift`? A Swift Package builds a raw binary with no
> bundle ID → `linkd.autoShortcut / missing main bundle identifier` spam
> and no proper window. The `.xcodeproj` (from `project.yml` via xcodegen)
> builds a real signed `SuperClean.app`, so Cmd+R just works.
> If you edit files: `xcodegen generate` to refresh the project.

## Structure (clean code, recognizable names)
```
Sources/SuperClean/
  SuperCleanApp.swift      # @main entry
  ContentView.swift        # 6-tab window
  Models/
    AppState.swift         # @Observable global state (dry-run, whitelist, results)
    ScanResult.swift       # One cleanable file (path + size + reason)
  Services/
    SafetyGate.swift       # MUST pass before any delete (test this most)
    CleanerService.swift   # Mole clean/purge logic in Swift + Trash
    CzkawkaBridge.swift    # Rust czkawka_cli via Process + JSON (mock in M1)
    MolePaths.swift        # Known-safe macOS paths (data from Mole)
    OperationLog.swift     # ~/Library/Logs/superclean/operations.log
  Views/
    Shared/ScanTab.swift   # Reusable scan→preview→trash UI (all tabs use it)
    Shared/SharedViews.swift # StatCard, PreviewRow, ScanButton
    MainTabs.swift         # Clean, Duplicates, Apps, Disk
    MoreTabs.swift         # Health, Toolbox (Purge/Installers/Fixers/History), Settings
Engines/README.md          # How to bundle czkawka_cli + ffmpeg
Resources/whitelist.default
```

## Efficiency notes
- `LazyVStack` for 100k rows, shallow size first, stream NDJSON line-by-line.
- Scans run in `Task.detached`, UI stays on MainActor.
- No polling loops, no daemons, no network calls.

## Safety (read before disabling dry-run)
1. Dry-run ON by default — Preview only.
2. Every result passes `SafetyGate.isAllowed` (blocks `/System`, `com.apple.*`, whitelist).
3. Deletes = `FileManager.trashItem` (reversible) + append to operations.log.
4. Needs Full Disk Access for `~/Library/Caches` — granted in System Settings.

## Roadmap
- [x] M1 UI shell + SafetyGate + mock data
- [x] M2 Mole-native: real clean/purge/installer + whitelist file (`~/.config/superclean/whitelist`)
- [ ] M3 Bundle `czkawka_cli`: duplicates/empty/big/similar via JSON
- [ ] M4 Notarized DMG + GitHub release

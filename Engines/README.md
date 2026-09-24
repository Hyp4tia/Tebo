# Engines (bundled helpers, not source forks)

## czkawka_cli (Rust, GPL-3.0, by qarmin)
- Source: https://github.com/qarmin/czkawka
- What we use: `krokiet` features via CLI JSON output.
- How to add (M3):
  ```sh
  cargo build -p czkawka_cli --release
  cp target/release/czkawka_cli SuperClean/Engines/
  ```
- Swift calls it in `Services/CzkawkaBridge.swift` via `Process` + NDJSON.
- Pin version: write commit hash here when you bundle.

Pinned: _none yet (M1 uses mock data)_

## Mole spec (Go+shell, GPL-3.0, by tw93)
- Source: https://github.com/tw93/Mole
- We do NOT bundle the Go binary. We reimplement the safe-path tables
  natively in `Services/MolePaths.swift` + `Services/CleanerService.swift`.
- Why: lighter, signable, easier to read, no shell-out to bash.

## ffmpeg (optional, for Similar Videos / Video Optimizer)
```sh
brew install ffmpeg
```
If missing, those tabs show "ffmpeg not found" and stay disabled.

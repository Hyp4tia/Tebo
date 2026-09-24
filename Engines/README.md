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

---

## Pinned engine (czkawka_cli)

Installed 2026-09-24 by `scripts/fetch-engine.sh` (idempotent, hash-pinned).

- Version: **czkawka 12.0.2** (commit `f9be31f`, built 09-09-2026) — `czkawka_cli --version`
- Binary: `Engines/czkawka_cli` (Mach-O arm64, 27,196,272 bytes) — **gitignored**, not committed
- sha256: `3362df5776b209b6365482768bc960e5a853f1b554787954c4a4c64e90bc2c75`
- Source: https://github.com/qarmin/czkawka/releases/download/12.0.2/mac_czkawka_cli_arm64
- License: **MIT** (czkawka_cli + czkawka_core are MIT; the GPL-3.0 applies only to the
  krokiet/cedinia members, which we never bundle). Note: the "GPL-3.0" note in the older
  section above is wrong for the CLI.
- Runtime deps: none for dup/image/music/etc.; **ffmpeg on PATH** for `video`/`broken`
  video checks.
- JSON contract: results go to a **file** via `-p`/`-C` (never stdout), silenced with
  `-N -M`, exit `11` means "items found" so we always pass `-W`. Never pass `-D`/`-y`.
  Ground-truth JSON fixtures for all 12 tools: `Tests/Fixtures/czkawka/`.


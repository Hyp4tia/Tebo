# Tebo audit

Measured facts only. Every number below comes from a command that can be re-run; anything not yet
measured says so instead of guessing.

Last updated: 2026-09-24 (M6: memory, process surface, network, signing audited).

## How to reproduce the checks

```sh
./scripts/verify.sh                    # build + unit tests + headless self-test
swift test --filter ScanMemoryTests    # memory guard (prints its own numbers)
swift run -c release Tebo --benchmark=30   # footprint across 30 scans + one real home pass
./scripts/release.sh                   # build, verify and sign the shipping DMG
```

## Memory

### Scan pipeline: flat

`swift test --filter ScanMemoryTests`, 30 scans over a generated 400-file tree:

```
scan memory: 30 rounds, 51 rows, control +0.00 MB, scans +0.25 MB, attributed +0.25 MB
```

30 scans moved the footprint by 0.25 MB in total (0.008 MB per scan), against a control run of 30
awaited no-ops that moved nothing. The pipeline does not retain per scan.

### The trap that was avoided

A standalone probe (`swiftc -O`, no app code) comparing four file-walking styles over 20 passes of
the same tree:

| Style | Growth per pass |
|---|---|
| `FileManager.enumerator(atPath:)` alone | ~0.30 MB |
| `enumerator(atPath:)` + `attributesOfItem` | ~0.30 MB |
| URL enumerator + `resourceValues` | ~0.02 MB |
| `contentsOfDirectory` + `resourceValues` | ~0.01 MB |

The string-based enumerator retains roughly 0.30 MB per pass; the URL-based enumerator and
`contentsOfDirectory` do not. The app uses only the latter two (checked across `Sources/`), and
`ScanMemoryTests` is the standing guard against a regression back to the retaining API.

### Why the GUI benchmark reports more

`--benchmark` runs inside a real SwiftUI process, so its numbers include the AppKit/SwiftUI runtime
warming up (window, graphics, lazy framework allocations). That drift is unrelated to scanning,
which is why the test-suite measurement above uses a control run. Use `--benchmark` to see the
app's real-world footprint; use the test for regression signal.

## Process execution surface

Every outbound process in the app, inspected at the call site:

| Call site | Binary | Bound | On expiry |
|---|---|---|---|
| `CzkawkaBridge` | the engine `EngineLocator` resolved inside the app bundle (or a hash-matching checkout copy) | none: scanning a large tree legitimately takes minutes | cancelling the scan terminates the child; no orphan engine is left running |
| `OptimizeRunner` | absolute system binaries from the ported catalog (`/usr/bin/defaults`, `/usr/sbin/periodic`, `/usr/bin/mdutil`, …) | 120 s default | child killed, reported as timed out (distinct from a cancellation) |
| `TimeMachineSnapshots` | `/usr/bin/tmutil listlocalsnapshots /` | 3 s polled deadline | child terminated, reported as timed out |

`Process.executableURL` plus an argument array at all three sites. No shell is involved anywhere:
`/bin/sh -c` and `zsh` appear in no source file. The engine is only ever passed its scan
subcommand, the folder, `-p <temp file>` and `-N -M -W`; the fix-in-place flag (`-F`) and any
deletion flag are passed nowhere in the app.

## Network

`grep -rnE "URLSession|URLRequest|NWConnection|CFStream|Socket" Sources/` returns nothing. No
networking code exists in the app, and the engine is invoked only with local scan subcommands.

## Entitlements and signing

- `Resources/Tebo.entitlements` holds an empty dictionary: the app requests nothing.
- Not sandboxed, so the checks that matter are no-network (above) and the delete path (below).
- Hardened runtime verified: `flags=0x10000(runtime)` on both Debug and Release builds.
- **Found and fixed while writing this audit:** Xcode injects `get-task-allow` (a debug entitlement
  that lets any process attach a debugger) into development-signed builds, and our Release build was
  carrying it. `scripts/release.sh` now builds with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` and fails
  the release outright if the entitlement is still present.
- Signed Apple Development (TeamIdentifier `RY4LJM4BM2`). Unnotarized by design: no Developer ID
  certificate exists on this machine. `scripts/notarize.sh` is ready for the day one does.

## Engine output parsing: verified against captured output

`Tests/Fixtures/czkawka/` holds real output captured from the shipped 12.0.2 binary: all twelve
tools as both `.json` and human-readable `.log`, three duplicate shapes (name, size, size+name) and
a manifest. The parsers are tested against those files rather than hand-written samples, so a
schema mistake shows up as a failing test instead of a wrong row in the UI.

## Delete path reviewed against Mole's rules

Reviewed at the call site, not from a summary:

- Mole splits its deny list into exact roots (only the leaf is refused) and protected trees (the leaf
  and every ancestor are refused). `PathValidator` mirrors that split with `exactProtectedRoots` /
  `protectedTreeRoots`, and both sets are actually consulted: the leaf's inode against the exact set,
  each ancestor's inode against the tree set.
- Both checks compare **inodes**, not strings, so a case-variant alias such as `/SYSTEM` on
  case-insensitive APFS is caught as the same file rather than sailing past a string compare.
- Homebrew carve-outs are preserved from Mole: `/usr/local/*` and `/opt/homebrew/*` stay deletable
  while the roots do not, so a single stale cell can still be reclaimed.
- Symlink resolution happens before the decision, and the resolved path is re-checked against the
  same deny rules. Deny-only on purpose: resolving a path can never upgrade it to allowed.
- `FileManager.trashItem` appears in exactly one place, `DeletePipeline`, and the pipeline re-reads
  the file's identity (device + inode) immediately before the move, so a path swapped between scan
  and delete is not what gets removed.

## Still open

- Not covered in v1.0: sudo-requiring system cleanup, scheduled task installation, and app
  uninstall of the bundle itself (left to Finder so a mistake stays recoverable).

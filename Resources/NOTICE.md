# NOTICE

Tebo is GPL-3.0 (see LICENSE). It is an independent app, not a fork or an official build of
either project below, and it is not endorsed by them.

## czkawka_cli, MIT

Bundled as `Contents/MacOS/czkawka_cli`, downloaded from the official release
`https://github.com/qarmin/czkawka/releases/download/12.0.2/mac_czkawka_cli_arm64` and verified
against a pinned SHA-256 before bundling; the installed helper and app seal are verified before use (see `Engines/README.md` and `scripts/fetch-engine.sh`).

Only `czkawka_cli` is bundled. The `krokiet` and `cedinia` frontends of that project are
GPL-3.0-only and are deliberately not shipped.

```
Copyright (c) 2020 Rafał Mikrut

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## tw93/Mole, GPL-3.0

Tebo reimplements Mole's cleanup behaviour natively in Swift. No Mole code or binary is
bundled or executed; the path tables, protection rules, and cleanup semantics were ported from
Mole's shell sources (cited per row as `source:` in `Sources/Tebo/Services/MoleTables/`).

Mole is Copyright (c) tw93 and contributors, licensed GPL-3.0 (`https://github.com/tw93/Mole`).

Per Mole's TRADEMARK.md: this project uses its own name and icon, does not imply endorsement or
affiliation with Mole, and credits Mole as the source of the cleanup knowledge. "Mole" and the Mole
logo remain trademarks of the Mole project.

## Sparkle, BSD-style license

Sparkle 2.10.0 provides signed updates for the external edition. Its copyright
and license are included in `Contents/Resources/Sparkle-LICENSE.txt` in release
packages. Official source: https://github.com/sparkle-project/Sparkle/tree/2.10.0.

## Portable video helpers

Release packages bundle `ffmpeg` and `ffprobe` in `Contents/MacOS`, built for
Apple Silicon and macOS 14 with static codec libraries. No Homebrew library is
required at runtime. Network and capture inputs are disabled in these helpers.

This FFmpeg 9.0.1 build enables GPL and version 3, including x264, x265, libvpx,
libaom and Opus. Their original copyright, license and patent notices are copied
into `Contents/Resources/VideoHelpers/`. The exact upstream pins are recorded in
`sources.json` there and in `scripts/build-video-helpers.py`.

Each GitHub release includes `Tebo-<version>-video-sources.tar.xz`, containing the
exact dependency snapshots, manifest and build recipe, alongside the app's own
source snapshot. Preserve and distribute those companions with the binary.

Official source projects:
- https://ffmpeg.org/
- https://code.videolan.org/videolan/x264
- https://github.com/Multicorewareinc/x265
- https://github.com/webmproject/libvpx
- https://aomedia.googlesource.com/aom
- https://opus-codec.org/

# NOTICE

Tebo is GPL-3.0 (see LICENSE). It is an independent app, not a fork or an official build of
either project below, and it is not endorsed by them.

## czkawka_cli — MIT

Bundled as `Contents/Helpers/czkawka_cli`, downloaded from the official release
`https://github.com/qarmin/czkawka/releases/download/12.0.2/mac_czkawka_cli_arm64` and verified
against a pinned SHA-256 before every use (see `Engines/README.md` and `scripts/fetch-engine.sh`).

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

## tw93/Mole — GPL-3.0

Tebo reimplements Mole's cleanup behaviour natively in Swift. No Mole code or binary is
bundled or executed; the path tables, protection rules, and cleanup semantics were ported from
Mole's shell sources (cited per row as `source:` in `Sources/Tebo/Services/MoleTables/`).

Mole is Copyright (c) tw93 and contributors, licensed GPL-3.0 (`https://github.com/tw93/Mole`).

Per Mole's TRADEMARK.md: this project uses its own name and icon, does not imply endorsement or
affiliation with Mole, and credits Mole as the source of the cleanup knowledge. "Mole" and the Mole
logo remain trademarks of the Mole project.

## ffmpeg — optional

Not bundled. If `ffmpeg` is present on the system, it enables similar-video and video file checks.
ffmpeg is licensed LGPL-2.1-or-later / GPL-2.0-or-later depending on the build.

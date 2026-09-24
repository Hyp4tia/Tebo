# czkawka fixture captures — ground truth for the Swift parsers

These files are the **real** JSON output of the pinned `Engines/czkawka_cli` (czkawka
12.0.2, commit f9be31f) run against the deterministic fixture tree built by
`scripts/build-fixture-tree.sh`. The Swift JSON parsers were written against these
captures, not against guessed schemas.

Regenerate with:

```sh
./scripts/capture-czkawka-fixtures.sh   # rebuilds the tree in $TMPDIR, re-runs all tools
```

That script delegates the 12-tool capture below to `scripts/capture-fixtures.sh`, then
adds the three dup search-method variants documented at the bottom of this file.

Captured 2026-09-24, when the app and its fixture tree were named Tebo (`ⲧⲉⲃⲟ`). The
absolute paths inside the captures carry the capture machine's temp directory and repo
path, which is why they read like a developer's machine: they are the command lines that
actually produced these files.

## Global facts (true for every capture below)

- **JSON goes to the file given by `-p`, never to stdout.** One JSON document per run.
  stdout was **empty in all 12 captures** (the `.log` files contain only the 3 header
  comment lines the capture script writes; `-N -M` silences results and messages).
- Every run used: `czkawka_cli <tool> -d <tree> -p <out>.json -N -M -W`.
  `-W` forces exit code 0 even when items were found. We **never** pass `-D` or `-y`
  (they make the scan destructive).
- Without `-W`: exit code is `0` (nothing found) or `11` (items found) — verified live
  (`dup` without `-W` exited 11; `image` with no matches exited 0).
- All paths are absolute paths under the (per-run) fixture tree; `modified_date` is the
  build-time unix timestamp. **Parsers/tests must not depend on either.**
- There is **no category/reason field anywhere** — Swift supplies category from tool +
  group context. Field order varies per tool (Swift Codable does not care, but do not
  write order-sensitive parsing).
- Per-tool exit codes, byte sizes and parse checks are in `manifest.json`.

## Per-tool shapes

### dup (`dup.json`) — exit 0, JSON present

Top-level: **object** keyed by file size as a decimal **string**.
Value per key: array of **groups**; each group is an array of entries.

Entry fields (exact): `path` (string), `modified_date` (unix s), `size` (bytes), `hash`
(64-char hex BLAKE3, default `-t` hash type).

```json
{
  "11401": [
    [
      {
        "path": ".../media/clip.mp4",
        "modified_date": 1790275498,
        "size": 11401,
        "hash": "0b2eadda2b1900fd11afeef6c368a5635d58ef5c0c2af09f4d3a6a74c0b2d167"
      },
      {
        "path": ".../media/clip_copy.mp4",
        "modified_date": 1790275498,
        "size": 11401,
        "hash": "0b2eadda2b1900fd11afeef6c368a5635d58ef5c0c2af09f4d3a6a74c0b2d167"
      }
    ]
  ],
  ...
}
```

Captured groups: clip pair (11401), trio (12288), pair (16384), JPEG-in-.txt + original
JPEG (byte copies with the same hash; the key equals their shared size, which drifts a
little per build as ffmpeg's encoder output varies), mp3 pair (33112). The
same-size-different-content pair (10000) is correctly **absent**.

### empty-folders (`empty-folders.json`) — exit 0

Top-level: **array of strings** (absolute folder paths). No objects.

```json
[
  ".../deep",
  ".../emptydir"
]
```

Observed: a folder whose entire subtree contains no files is reported (`deep` contains
only the empty `nested_emptydir`).

### empty-files (`empty-files.json`) — exit 0

Top-level: **array** of entries `{path, size, modified_date}` (note field order — `size`
before `modified_date` here).

```json
[
  {
    "path": ".../misc/empty.dat",
    "size": 0,
    "modified_date": 1790275498
  }
]
```

The 1-byte `blank.txt` is correctly not reported. No flags were passed: the bare tool
finds zero-byte files on its own (`--zero-byte-content` / `--non-printable-content`
extend it).

### big (`big.json`) — exit 0

Top-level: **array** of entries `{path, size, modified_date}`, sorted by size
**descending** (default `-n` 50). 25 entries captured.

```json
[
  {
    "path": ".../media/song_b.mp3",
    "size": 33112,
    "modified_date": 1790275498
  },
  ...
]
```

Observed: zero-byte files are excluded (26 files in tree, 25 reported; `empty.dat` absent).

### temp (`temp.json`) — exit 0

Top-level: **array** of entries `{path, modified_date, size}`.

```json
[
  {
    "path": ".../misc/backup.bak",
    "modified_date": 1790275498,
    "size": 512
  },
  ...
]
```

Default extension list flags `.bak`, `.part`, `.tmp` (3 entries). `editor.save` is not
flagged (not in the default list).

### symlinks (`symlinks.json`) — exit 0

Top-level: **array** of entries `{path, size, modified_date, symlink_info}`.
`symlink_info`: `{destination_path: string, type_of_error: string}` (observed value
`"NonExistentFile"`). The top-level `size` here is the symlink's own length (92 bytes =
length of the target path it stores), not the target's.

```json
[
  {
    "path": ".../broken-link",
    "size": 92,
    "modified_date": 1790275498,
    "symlink_info": {
      "destination_path": ".../missing-target.txt",
      "type_of_error": "NonExistentFile"
    }
  }
]
```

### broken (`broken.json`) — exit 0

Top-level: **array** of entries `{path, modified_date, size, errors}`.
`errors` is an **object keyed by check-type name** (observed keys: `"Pdf"`, `"Image"`)
mapping to a human-readable error string.

```json
[
  {
    "path": ".../docs/broken.pdf",
    "modified_date": 1790275498,
    "size": 281,
    "errors": {
      "Pdf": "failed parsing cross reference table: invalid start value"
    }
  },
  {
    "path": ".../misc/ bad name .JPG",
    "modified_date": 1790275498,
    "size": 300,
    "errors": {
      "Image": "Format error decoding Jpeg: Error parsing image. Illegal start bytes:5375"
    }
  }
]
```

Default checked types include PDF and IMAGE (content sniffing, not extension: text bytes
wearing a `.JPG` name fail the Image check; the JPEG-in-.txt does not because its
content is a valid image). Video checks (ffprobe/ffmpeg) passed the fixture mp4s.

### ext (`ext.json`) — exit 0

Top-level: **array** of entries
`{path, modified_date, size, current_extension, proper_extensions_group, proper_extension}`.

```json
[
  {
    "path": ".../misc/fake_image.txt",
    "modified_date": 1790275498,
    "size": 27791,
    "current_extension": "txt",
    "proper_extensions_group": "(jpg) - jfif,jpe,jpeg,jpg",
    "proper_extension": "jpg"
  }
]
```

Only the JPEG-named-.txt is flagged. The text file named `.JPG` is **not** flagged —
the tool only reports when it can positively identify the content type (text content is
never "wrong" for it).

### bad-names (`bad-names.json`) — exit 0, **requires check flags**

Command line (the one exception to the bare flag set):
`czkawka_cli bad-names -d <tree> -p bad-names.json -N -M -W -u -w`

Top-level: **array** of entries `{path, modified_date, size, new_name}`.
`new_name` is the proposed fixed name (present even though we never pass `-F`).

```json
[
  {
    "path": ".../misc/ bad name .JPG",
    "modified_date": 1790275498,
    "size": 300,
    "new_name": "bad name.jpg"
  }
]
```

**Verified:** `bad-names` with no check flags returns `[]` — checks are opt-in via
`-u` (uppercase ext), `-j` (emoji), `-w` (leading/trailing spaces), `-n` (non-ASCII),
`-a` (duplicated non-alphanumerics). Swift must pass at least one.

### image (`image.json`) — exit 0

Top-level: **array of groups**; each group is an array of entries
`{path, size, width, height, modified_date, hashes, difference}`.

```json
[
  [
    {
      "path": ".../photos/sunset.jpg",
      "size": 27791,
      "width": 1280,
      "height": 960,
      "modified_date": 1790275498,
      "hashes": [],
      "difference": 0
    },
    ...
  ]
]
```

One group of 3 captured (original, brightness variant, downscaled variant — cross-size
matching works with default settings). `hashes` is **always `[]`** in CLI JSON; the
useful field is `difference` (0 = identical hash).

**Pitfall verified:** the image tool's default `--minimal-file-size` is **16384 bytes**
(not documented in the reference; read from `SimilarImagesArgs` in
`czkawka_cli/src/commands.rs`). Smaller images are silently skipped — an earlier fixture
with ~10–16KB JPEGs produced `[]` until the photos were regenerated above 16KB.

### music (`music.json`) — exit 0

Top-level: **array of groups**; each group is an array of entries:
`{size, path, modified_date, fingerprint, track_title, track_artist, year, length, genre, bitrate}`.

```json
[
  [
    {
      "size": 33112,
      "path": ".../media/song_a.mp3",
      "modified_date": 1790275498,
      "fingerprint": [],
      "track_title": "Fixtune Alpha",
      "track_artist": "Fixture Artist",
      "year": "",
      "length": 2,
      "genre": "",
      "bitrate": 129
    },
    ...
  ]
]
```

Default search method is TAGS with similarity `track_title,track_artist`: all three
tagged mp3s (incl. the byte copy and a *different* recording with the same tags) form
one group. `fingerprint` is `[]` in TAGS mode. Default `--minimal-file-size` is 8192.

### video (`video.json`) — exit 0 — the big one (25.7 KB)

Top-level: **array of groups**; each group is an array of entries:
`{path, size, modified_date, signature, error, fps, codec, bitrate, width, height, duration}`.

```json
[
  [
    {
      "path": ".../media/clip.mp4",
      "size": 11401,
      "modified_date": 1790275498,
      "signature": {
        "path": ".../media/clip.mp4",
        "duration_ms": 2000,
        "aspect_ratio": 1.3333334,
        "visual_hashes": [
          { "start_ms": 300, "end_ms": 1500, "bits": [ 192, 2, 0, ... ] },
          ... (5 windows by default)
        ],
        "audio_fingerprint": null,
        "metadata": {
          "duration_secs": 2.0,
          "fps": 15.0,
          "codec": "h264",
          "bitrate_bps": 40668,
          "width": 320,
          "height": 240
        }
      },
      "error": "",
      "fps": 15.0,
      "codec": "h264",
      "bitrate": 40668,
      "width": 320,
      "height": 240,
      "duration": 2.0
    },
    ... (same shape for clip_copy.mp4)
  ]
]
```

`clip.mp4` + byte-identical `clip_copy.mp4` form one group. **ffmpeg is required at
runtime** for this tool. `signature.visual_hashes[].bits` is a flat array of up to
64x64 = 4096 small ints (truncated in the snippet above). Default
`--minimal-file-size` is 8192 — the 11 KB clip qualifies.

## dup search-method variants (captured live, not derived from source)

The main `dup.json` uses the default HASH method. The other three `-s` methods change
the JSON shape; all three below were captured against the real binary with a few
same-name files added under `extras/` (see `scripts/capture-czkawka-fixtures.sh`).
In SIZE/NAME/SIZE_NAME modes the engine never hashes: every entry's `hash` is `""`.

### dup-size.json — `dup -s SIZE`

Object keyed by size string; each value is ONE FLAT array of entries
(`{path, modified_date, size, hash:""}`). Same-size-different-content pairs group here
(entries 10000: `samesize_a.txt` + `samesize_b.txt`).

```json
{
  "10000": [
    { "path": ".../dup/samesize_a.txt", "modified_date": 1790276109, "size": 10000, "hash": "" },
    { "path": ".../dup/samesize_b.txt", "modified_date": 1790276109, "size": 10000, "hash": "" }
  ]
}
```

### dup-name.json — `dup -s NAME`

Object keyed by FILE NAME string; each value is one flat entry array. Same name,
different sizes still group (the `small.bin` key holds a 9216-byte and a 10240-byte
file). With no same-name files the output is `{}` (2 bytes).

### dup-size-name.json — `dup -s SIZE_NAME`

**Bare array of groups, no keys at all.** The map's (size, name) tuple keys are dropped
by the serializer, so Swift rebuilds a stable group ID from the first entry
(`size_name:<size>:<filename>`). Empty result is `[]`.

```json
[
  [
    { "path": ".../extras/subA/report.txt", "modified_date": 1790276174, "size": 10240, "hash": "" },
    { "path": ".../extras/subB/report.txt", "modified_date": 1790276174, "size": 10240, "hash": "" }
  ],
  [
    { "path": ".../extras/subA/other.txt", "modified_date": 1790276174, "size": 12288, "hash": "" },
    { "path": ".../extras/subB/other.txt", "modified_date": 1790276174, "size": 12288, "hash": "" }
  ]
]
```

## Regeneration caveats

- Rebuilding the tree changes file sizes/timestamps slightly (ffmpeg encodes are
  content-dependent); shapes, group structure and field sets are stable. Re-capture and
  commit both `.json` and `.log` files together.
- The tree lives in `$TMPDIR/tebo-fixture-tree` (never committed).
- czkawka keeps a cache under
  `~/Library/Application Support/pl.Qarmin.Czkawka/cache/` — harmless, and results did
  not differ between cached and `-H` (no-cache) runs in testing.

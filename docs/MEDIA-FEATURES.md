# Media cleanup: native Krokiet workflows

Implemented against the bundled, verified Czkawka CLI 12.0.2. Krokiet is the
upstream graphical frontend for this core. Tebo supplies its own SwiftUI interface
in the approved three-column shell; no Krokiet window is embedded.

Official reference: [Krokiet instructions](https://github.com/qarmin/czkawka/blob/master/instructions/Instruction_Krokiet.md)
and [Krokiet README](https://github.com/qarmin/czkawka/blob/master/krokiet/README.md).
Actual argument contracts come from the bundled binary's help. Upstream master
can contain controls newer than that binary; this map describes Tebo's implementation.

| Page | Real functions |
| --- | --- |
| Similar Images | Perceptual hash comparison, hash algorithm/size, resize filter, geometry invariance, difference threshold, same-size/resolution exclusions; list, image grid and grouped comparison |
| Duplicates | Content hash, size, name or size/name matching; BLAKE3/CRC32/XXH3; reviewed groups and protected references |
| Similar Videos | Visual temporal-window matching or audio fingerprints, threshold/duration/window controls, crop detection and same-size/resolution exclusions; requires ffmpeg |
| Similar Music | Music-tag matching or audio fingerprints, tag selection, approximate tags, segment duration and difference controls |
| File Checks | Large/small files, empty folders, empty files, temporary files, invalid links, damaged files, wrong extensions and bad names |
| Media Tools | EXIF-tag discovery, video-transcode plans and black-bar/static-content crop plans; native exports of selected copies |

All 14 upstream tool families are reachable; Video Optimizer is represented by
Transcode and Crop. History is shared with File cleanup. The unsupported Auto
Clean shortcut was removed from this workspace.

## Scan controls and results

Each scanner uses included and excluded folders, protected reference folders,
recursive search, extension/pattern exclusions and CPU-thread controls. Size
limits are exposed for the grouped comparison tools that support them. Scan
settings are saved between launches. Filter/comparison reset retains chosen
folders. Results are tied to their settings, and changing the current scan scope
clears stale rows and selections. Composite sidebar and overview totals use real
cached findings and deduplicate paths.

Reference directories are scanned as comparison inputs and their rows are kept
read-only. Recommendations preserve a reference copy or the largest editable
copy. Size/name matches and weaker duplicate hash modes have no default removal
selection. Similar-media suggestions require reviewing the differences; image
hash distance is displayed as a score, not an invented visual-match percentage.
Source identities, sizes and modification times are checked again before a Trash
move or export. Matching reference copies are also rechecked before removing
working copies. Empty folders are rechecked for newly added files.

## Copy exports

Metadata exports use ImageIO's lossless copy operation. GPS, camera/date and other
unselected EXIF/IPTC/XMP metadata are removed from the copy. Specified tags and
essential image orientation are retained; structural metadata may remain. Formats
not supported by ImageIO's lossless copy operation report a failure.

Video exports use ffmpeg with H.264, HEVC, AV1 or VP9 output, quality controls,
optional maximum dimensions and an optional smaller-result requirement. Crop
exports use the actual rectangle detected by the engine. Size limits never upscale
smaller sources. Video exports are 8-bit copies with audio; subtitles and auxiliary
tracks are omitted. Local file/pipe protocols are the only accepted export inputs.
The corresponding ffmpeg encoder and ffprobe must be available locally.

Preview performs no export writes. Actual exports require an output directory and
confirmation. Each output uses a new exclusive filename, and originals are never
rewritten. Whitelisted and reference output folders are refused. Failed/cancelled temporary work is cleaned up; already completed copies
remain in the output folder and are logged.

## Boundaries

- File removal remains recoverable through DeletePipeline and the Trash. No engine
  delete, fix-in-place or overwrite-original flags are passed.
- Wrong-extension and bad-name tools report suggestions for review; they do not
  rename originals in place. Invalid links are read-only Finder review entries.
- Hash caches are isolated per scan. Tebo saves the last scan settings, not
  Krokiet's separate application settings, language/theme preferences or preset files.
- Format coverage follows the bundled core and installed helpers. Optional RAW,
  HEIF/AVIF support is not claimed where it has not been verified.
- Full Disk Access restrictions still apply. A failed scan shows its error;
  unavailable functionality never returns fabricated rows.

The [task record](../.hermes/plans/2026-10-12_krokiet-media-workspace.md) owns test,
build, native UI and Git checkpoint evidence. Captured engine contracts and export
inputs are under `Tests/Fixtures/czkawka/` and `Tests/Fixtures/media/`.

# Verified helper engines

## Czkawka CLI

Tebo bundles the MIT-licensed Czkawka CLI and adapts Krokiet's tool families in
native SwiftUI. Krokiet and Cedinia frontends are not bundled.

- Pinned version: 12.0.2, arm64.
- Official binary: https://github.com/qarmin/czkawka/releases/download/12.0.2/mac_czkawka_cli_arm64
- SHA-256 before signing: `3362df5776b209b6365482768bc960e5a853f1b554787954c4a4c64e90bc2c75`.
- Fetch with `scripts/fetch-engine.sh`. Engines/czkawka_cli is generated and ignored.
- Release location: Contents/MacOS/czkawka_cli. The app checks its signature and
  bundle seal before execution; signing changes the bytes, so the source digest
  is only the loose-download/build-input check.
- CzkawkaBridge uses BoundedProcessRunner. Results go to a JSON file through `-p`,
  with `-N -M -W`; no JSON is expected on stdout. Never pass fix/delete flags.
- Captured tool contracts are in Tests/Fixtures/czkawka. The Media feature map in
  docs/MEDIA-FEATURES.md owns supported tools and boundaries.

## Mole knowledge

Official source: https://github.com/tw93/Mole. Tebo ports cleanup path tables and
protection semantics into Sources/Tebo/Services/MoleTables and native services.
No Mole shell script or binary is executed. Rows retain their source citations.
See docs/MOLE-FEATURES.md and Resources/NOTICE.md.

## Portable FFmpeg and codecs

External releases bundle ffmpeg and ffprobe in Contents/MacOS, built for arm64
with macOS 14 as the deployment target. All dynamic dependencies are system
libraries; no installed Homebrew libraries are required at runtime. The bundled
pair is verified and preferred over developer environment overrides.

Build with `python3 scripts/build-video-helpers.py --jobs 6`. The recipe owns exact
upstream archive digests and Git commits for FFmpeg, x264, x265, libvpx, libaom and
Opus. It enables H.264, H.265, VP9 and AV1 exports with local file/pipe inputs only.
Source snapshots, notices, licenses and the recipe accompany release packages.

Developer builds without the portable pair can still discover an installed
ffmpeg through the existing override or known paths. A present but untrusted or
incomplete bundled pair is refused. Release packaging requires the complete pair
and its corresponding source companion. See docs/RELEASING.md.

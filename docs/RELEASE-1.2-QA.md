# Tebo 1.2 release verification

Checked 2026-10-14 and 2026-10-15 on an arm64 Mac running macOS 27.0.1.
Release version 1.2, internal build 3. The full external edition is prepared;
App Store work is deferred by the user. Public publication requires approval.

## Signing and delivery

- Final app and every Czkawka/video/Sparkle component carry timestamped Developer
  ID signatures from the configured team. Strict deep signature verification passed.
- Release has hardened runtime, no get-task-allow and no library-validation exception.
- Apple accepted both the app and DMG. Stapled tickets validated, and Gatekeeper
  accepted both with source Notarized Developer ID.
- Appcast and archive Ed25519 signatures verified using the app's configured key.
  Release requires signed feeds and validation before archive extraction.
- Final DMG SHA-256: `43119eba0ce12e81232599e745edce4580355677ad0584f05500cf39ac5af5d1`.
- Packages include the original icon/artwork, licenses/notices, portable helpers,
  app-source snapshot and exact video-dependency source snapshots/build recipe.

## Real updater checks

A disposable Debug copy at visible version 1.1/build 2 used an explicitly enabled
loopback-only test feed. Its HTTP exception was limited to that test bundle.
The Release binary contains no loopback override or ATS exception.

1. A same-length change to the signed feed failed cryptographic verification.
   The native updater displayed "The update feed is improperly signed".
2. A one-byte corruption of the archive failed validation in the native updater.
   The older app remained installed; no corrupted update was installed.
3. The exact final notarized DMG was served through a valid signed local feed.
   Download, validation, Install and Relaunch completed. The installed copy reported
   version 1.2/build 3; executable and all helper bytes matched the release target.
   Its Developer ID signature and Gatekeeper assessment passed. HTTPS production
   feed settings replaced the disposable test configuration.
4. Before the first public feed exists, manual checking displays a recoverable
   retrieval error. The app remains usable. Actual GitHub delivery is pending
   publication of the first stable release with appcast.xml and its matching DMG.

The local test server was stopped. No signing private key was exported or uploaded.
Future releases must increase the internal build number and use the same update key.

## Operating conditions

- Full verification gate: 217 tests in 32 suites, native Release build and bundle
  self-test passed. Compiler and script syntax checks passed.
- All four portable video encoders exported real fixture copies. ffprobe confirmed
  H.264, HEVC, VP9 and AV1, the expected dimensions, and unchanged source bytes.
- Bundle self-test resolved the signed Czkawka and video helpers outside the checkout
  with PATH limited to /usr/bin:/bin and a nonexistent external ffmpeg override.
  otool found only system-library helper dependencies and minimum OS <= 14.
- Native Trash confirmation moved only a disposable 47 KB fixture. Finder Put Back
  restored its exact bytes, SHA-256 `98faea760e91e6fece72cf359921cc5de2726f49f4ac6a50a6beb4277b7c5fc4`.
- A real 24-file scan totaling 24 GiB of logical sparse payloads completed in 15.4 s.
  Another active scan accepted search input and cancellation, returning to idle
  in approximately 0.8 s from Cancel. Prior results remained available.
- A real 5,000-file collection produced 250 duplicate groups in 2.9 s. Filtering
  returned the expected 20-file group with 19 recommendations. Full accessibility
  snapshots could time out on this large tree; visual rendering and filtering were
  verified separately, so a tool timeout was not treated as an app crash.
- Permission-off operation was checked first. After the user refreshed the stale
  development-build entry for the Developer ID app, protected access was confirmed.
  Native Clean completed in 12.7 s: 242 selectable items, 9.04 GB measured and 553
  kept-back entries. Preview stayed on and no personal files were moved.
- Access status now re-probes when the app becomes active. Failed probes no longer
  assert that the System Settings switch is off. The current settings URL is used.
- At 1121 x 773 logical points, all six overview rows remained visible. Live blur
  changed the main artwork while Settings stayed open. Original blur 0, Preview on,
  automatic checks off and home-folder media scan settings were restored.

## Practical limits

This was verification on the available Mac, not a physical test on every supported
macOS version or a separate fresh Mac. The macOS 14 deployment target, Mach-O minimums
and absence of Homebrew runtime dependencies were checked. Administrator-only
maintenance remains manual by design. No App Store submission or public release
has been performed by this verification work.

See [the release guide](RELEASING.md) for packaging and update publication steps.

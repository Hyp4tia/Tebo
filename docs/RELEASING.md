# External releases

Tebo 1.2 is the first external edition with Sparkle updates. App Store work is
explicitly deferred. Scanning remains local; the optional updater uses GitHub.

## Local prerequisites

- Xcode, XcodeGen and Python 3.12 or newer.
- Developer ID Application certificate and private key for team RY4LJM4BM2 in the
  login Keychain. Development or ad-hoc identities are refused for releases.
- Notarization credentials stored as `tebo-notary`, or set NOTARY_PROFILE.
  Create the profile interactively with `xcrun notarytool store-credentials
  tebo-notary --team-id RY4LJM4BM2`. Keep passwords and keys out of chat and Git.
- Sparkle update key in the login Keychain account `com.tebo.updates`. The app's
  SUPublicEDKey must match. Preserve that private key securely; replacing it
  prevents installed builds from accepting new updates. Never commit the key.
- Verified Czkawka helper from `scripts/fetch-engine.sh`.
- Portable helpers from `python3 scripts/build-video-helpers.py --jobs 6`.
  The builder uses pinned upstream snapshots and produces the corresponding
  source companion. Building needs clang, make, CMake and pkg-config.

## Prepare and notarize

1. Update MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml. The build
   number must increase for every published update, even if the visible version
   stays the same. Commit the final source, run `./scripts/verify.sh`, and review it.
2. Run `./scripts/release.sh --version 1.2 --build 3`. This runs the gate, checks the
   engine/update key/helper sources, and builds a timestamped Developer ID app.
   Output goes to a unique `dist/<version>-<build>-<UTC>/` directory. Prior release
   outputs are preserved. `--skip-verify` is only for a gate that just passed.
3. Run `./scripts/notarize.sh <that-directory>`. It submits the app archive to
   Apple, requires Accepted, staples and verifies the app, then creates, submits
   and staples the DMG. Gatekeeper must accept both. Only then does it generate
   and verify the signed appcast and archive signature. Review-ready artifacts
   appear in `<that-directory>/ready/`.
4. Review the app, source companions, release notes and SHA256SUMS.txt. Then run
   `./scripts/draft-release.sh <ready-directory> --commit <pushed-commit-SHA>`.
   This verifies hashes and the signed feed before creating a GitHub **draft**.
5. After human approval, publish the draft as the latest stable release. The
   updater's URL is `https://github.com/Hyp4tia/Tebo/releases/latest/download/appcast.xml`.
   Every stable release must include appcast.xml, the exact DMG it signs, checksums
   and both source companions. Editing the DMG or XML after signing invalidates it.

The scripts never publish publicly or export credentials. A source snapshot and
exact FFmpeg/codec snapshots accompany the binary. LICENSE and dependency notices
are bundled. Tools use Sparkle 2.10.0 with a pinned distribution digest.

## Release checks and boundaries

The package must contain the icon/artwork, native updater, Czkawka, ffmpeg/ffprobe,
notices and licenses. Helper dependencies must be system libraries only; their
minimum OS may not exceed macOS 14. Release entitlements may not allow debugging
or disable library validation. Portable exports cover H.264, H.265, VP9 and AV1.

The updater enforces HTTPS in Release, signed feeds, signed archives and validation
before extraction. A Debug-only loopback flag exists for disposable upgrade tests;
it is absent from Release and never enables unsigned updates. No telemetry or
system-profile submission is enabled. Version 1.2 is published with the production
feed. Older builds without Sparkle need one manual installation of 1.2. Later
releases are delivered through Check for Updates in Tebo, or through automatic
checks when the user enables them in Settings.

The checked operating conditions and practical limits are recorded in
[the 1.2 verification record](RELEASE-1.2-QA.md).

Sources: [Sparkle publishing](https://sparkle-project.org/documentation/publishing/)
and [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

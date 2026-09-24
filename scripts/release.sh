#!/bin/bash
# release.sh — build, sign, and package Tebo as a distributable DMG.
#
# Usage:  ./scripts/release.sh [--unsigned]
#   --unsigned   skip code signing entirely (build-and-package smoke test only)
#
# Env overrides:
#   SIGN_IDENTITY   code signing identity to use (default: auto-detected, prefers
#                   "Developer ID Application", falls back to "Apple Development")
#
# Output: dist/Tebo-<version>.dmg  (+ sha256 printed at the end)
#
# Why a plain hdiutil and not create-dmg: the release path should not depend on
# anything a fresh Mac does not already ship.
#
# Notarization is a separate step: scripts/notarize.sh (needs a Developer ID).

set -euo pipefail
cd "$(dirname "$0")/.."

UNSIGNED=0
[[ "${1:-}" == "--unsigned" ]] && UNSIGNED=1

APP_NAME="Tebo"
DD=".build/release-xcode"
STAGE=".build/dmg-stage"
DIST="dist"

die() { echo "RELEASE ERROR: $1" >&2; exit 1; }
step() { echo; echo "==> $1"; }

# ---------------------------------------------------------------- 1. engine
step "1/7 engine"
[[ -f Engines/czkawka_cli ]] || die "Engines/czkawka_cli is missing — run ./scripts/fetch-engine.sh first"
EXPECTED_ENGINE_SHA="$(grep -E '^EXPECTED_SHA256=' scripts/fetch-engine.sh | head -1 | cut -d'"' -f2)"
ACTUAL_ENGINE_SHA="$(shasum -a 256 Engines/czkawka_cli | awk '{print $1}')"
[[ "$ACTUAL_ENGINE_SHA" == "$EXPECTED_ENGINE_SHA" ]] \
  || die "bundled engine does not match the pinned digest (expected $EXPECTED_ENGINE_SHA, got $ACTUAL_ENGINE_SHA)"
echo "engine sha256 matches the pin ($EXPECTED_ENGINE_SHA)"

# ---------------------------------------------------------------- 2. identity
step "2/7 signing identity"
IDENTITY="${SIGN_IDENTITY:-}"
if [[ "$UNSIGNED" == "1" ]]; then
  IDENTITY="-"
  echo "signing disabled on request (ad-hoc)"
elif [[ -z "$IDENTITY" ]]; then
  # Prefer the shipping identity, fall back to the development one so a
  # developer without a Developer ID can still produce an installable DMG.
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  [[ -n "$IDENTITY" ]] || IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
  [[ -n "$IDENTITY" ]] || die "no code signing identity found (use --unsigned for an ad-hoc build)"
  echo "using: $IDENTITY"
fi

# ---------------------------------------------------------------- 3. build
step "3/7 release build"
rm -rf "$DD"
xcodebuild \
  -project Tebo.xcodeproj \
  -scheme Tebo \
  -configuration Release \
  -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  build 2>&1 | grep -E "error:|warning:|^\*\* |bundled czkawka_cli" || true
APP="$DD/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || die "$APP was not produced (see the build output above)"
VERSION="$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)"
[[ -n "$VERSION" ]] || die "could not read CFBundleShortVersionString"

# ---------------------------------------------------------------- 4. verify
step "4/7 verify the bundle"
BUNDLE_ID="$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleIdentifier)"
[[ "$BUNDLE_ID" == "com.tebo.app" ]] || die "unexpected bundle id: $BUNDLE_ID"
[[ -f "$APP/Contents/Resources/$APP_NAME.icns" ]] || die "app icon missing from the bundle"
[[ -f "$APP/Contents/MacOS/czkawka_cli" ]] || die "engine missing from the bundle"
[[ -f "$APP/Contents/Resources/NOTICE.md" ]] || die "NOTICE.md missing from the bundle"
"$APP/Contents/MacOS/$APP_NAME" --selftest | sed 's/^/    /'
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
# get-task-allow is a debug entitlement that lets any process attach a debugger to the shipped app.
# Xcode injects it into development-signed builds, so the build sets
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO and this asserts it actually took effect.
if codesign -d --entitlements - "$APP" 2>&1 | grep -q "get-task-allow"; then
  die "the app still carries get-task-allow; the release build must not be debuggable"
fi
echo "    entitlements: none beyond the hardened runtime"
if [[ "$UNSIGNED" == "0" ]]; then
  # --verbose=2 is required: plain `codesign -dv` does not print Authority at all.
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
    && echo "    signed with a Developer ID (notarization-ready)"
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier)" | sed 's/^/    /'
fi
echo "bundle verified: id=$BUNDLE_ID version=$VERSION"

# ---------------------------------------------------------------- 5. stage
step "5/7 stage the disk image"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/FIRST-LAUNCH.txt "$STAGE/First Launch.txt"

# ---------------------------------------------------------------- 6. dmg
step "6/7 create the disk image"
rm -rf "$DIST"
mkdir -p "$DIST"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG" \
  || die "hdiutil failed"
if [[ "$IDENTITY" != "-" ]]; then
  # Signing the image itself is what lets Gatekeeper show the developer name
  # instead of "unidentified developer" once the app is notarized.
  # A Developer ID signature needs a secure timestamp (and notarization rejects
  # it without one), so only development builds skip the network round trip.
  if [[ "$IDENTITY" == Developer\ ID* ]]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  else
    codesign --force --sign "$IDENTITY" --timestamp=none "$DMG"
  fi
fi

# ---------------------------------------------------------------- 7. report
step "7/7 summary"
SIZE="$(du -h "$DMG" | awk '{print $1}')"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "    dmg:      $DMG"
echo "    size:     $SIZE"
echo "    sha256:   $SHA"
echo "    signed:   $IDENTITY"
echo
echo "Install steps for the recipient (also inside the image as 'First Launch.txt'):"
echo "    1. drag Tebo.app to /Applications"
echo "    2. right-click the app -> Open -> Open (once, because it is not notarized)"
echo "    3. System Settings -> Privacy & Security -> Full Disk Access -> add Tebo"
echo
if [[ "$IDENTITY" == Apple\ Development* ]]; then
  echo "NOTE: signed with a development certificate. macOS will still warn on first open"
  echo "      and users must use right-click -> Open. Run scripts/notarize.sh once a"
  echo "      Developer ID certificate exists (set SIGN_IDENTITY to it) to remove that step."
fi

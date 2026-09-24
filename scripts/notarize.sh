#!/bin/bash
# notarize.sh — submit a SuperClean DMG to Apple and staple the ticket.
#
# This is the step that removes the "right-click to open" workaround. It needs
# two things this repo cannot generate for you:
#
#   1. A "Developer ID Application" certificate in your keychain (Apple
#      Developer Program membership). Create it in Xcode:
#      Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application
#
#   2. A stored notarytool credential profile (created once, interactive):
#        xcrun notarytool store-credentials "superclean-notary" \
#          --apple-id "you@example.com" \
#          --team-id "YOURTEAMID" \
#          --password "app-specific-password"
#
# Usage:  ./scripts/notarize.sh [path/to/SuperClean-1.0.dmg]
# Env:    NOTARY_PROFILE   credential profile name (default: superclean-notary)
#         SIGN_IDENTITY   Developer ID identity, if the DMG was not signed with it
#
# Order of operations matters: the DMG must already be signed with the
# Developer ID (scripts/release.sh does that when SIGN_IDENTITY points at one),
# because notarization validates the signature inside the ticket it issues.

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-superclean-notary}"
DMG="${1:-}"

die() { echo "NOTARIZE ERROR: $1" >&2; exit 1; }
step() { echo; echo "==> $1"; }

step "1/5 locate the disk image"
if [[ -z "$DMG" ]]; then
  DMG="$(ls -t dist/*.dmg 2>/dev/null | head -1 || true)"
fi
[[ -n "$DMG" && -f "$DMG" ]] || die "no DMG found — run ./scripts/release.sh first, or pass a path"
echo "image: $DMG"

step "2/5 check the toolchain and credentials"
xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found (needs Xcode 13+)"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[[ -n "$IDENTITY" ]] || die "no 'Developer ID Application' certificate in the keychain — see the header of this script"
echo "identity: $IDENTITY"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  die "keychain profile '$PROFILE' is missing or unusable — create it with:
    xcrun notarytool store-credentials \"$PROFILE\" --apple-id <you> --team-id <TEAMID> --password <app-specific-password>"
fi

step "3/5 verify the signature before submitting"
codesign --verify --strict --verbose=2 "$DMG" 2>&1 | sed 's/^/    /'
AUTHORITY="$(codesign -dv "$DMG" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')"
[[ "$AUTHORITY" == Developer\ ID\ Application* ]] \
  || die "the image is signed by '$AUTHORITY', not a Developer ID — re-run scripts/release.sh with SIGN_IDENTITY=\"$IDENTITY\""
echo "     signed by: $AUTHORITY"

step "4/5 submit and wait for Apple"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

step "5/5 staple and verify"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo
echo "Notarized and stapled: $DMG"
echo "Recipients can now just drag it to Applications and open it — no right-click step."
echo "Reminder: the FIRST-LAUNCH.txt inside the image is now out of date for this build."

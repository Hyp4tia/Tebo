#!/bin/zsh
# build-app.sh — wrap the SwiftPM binary into a real Tebo.app bundle.
# Why: running `.build/debug/Tebo` directly has no bundle ID,
# so macOS logs linkd.autoShortcut / "missing main bundle identifier".
# Running as .app fixes all of those warnings.
#
# Usage:
#   ./build-app.sh        # debug build + open
#   ./build-app.sh release # optimized build

set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-debug}"
if [[ "$MODE" == "release" ]]; then
  swift build -c release
  BIN=".build/release/Tebo"
else
  swift build
  BIN=".build/debug/Tebo"
fi

APP="Tebo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Tebo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Tebo.icns Resources/TeboLogo.png Resources/NOTICE.md "$APP/Contents/Resources/"
cp Resources/whitelist.default "$APP/Contents/Resources/" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Tebo" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.tebo.app" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Tebo" "$APP/Contents/Info.plist"
RESOURCE_BUNDLE=".build/$MODE/Tebo_Tebo.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi

echo "Built $APP"
if [[ "${TEBO_NO_OPEN:-0}" != "1" ]]; then
  open "$APP"
fi

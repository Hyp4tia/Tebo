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
cp Resources/whitelist.default "$APP/Contents/Resources/" 2>/dev/null || true

echo "Built $APP — opening…"
open "$APP"

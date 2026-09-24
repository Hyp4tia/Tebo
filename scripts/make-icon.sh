#!/bin/zsh
# make-icon.sh — builds Resources/SuperClean.icns from scripts/make-icon.swift.
#
# Usage: ./scripts/make-icon.sh
# Swap the mark by editing the symbol list / gradient in make-icon.swift, then re-run this.
# The .icns is committed so a plain `xcodegen generate` build has an icon without re-running this.

set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASE="$WORK/icon-1024.png"
swift scripts/make-icon.swift "$BASE"

ICONSET="$WORK/SuperClean.iconset"
mkdir -p "$ICONSET"

# Every size macOS asks for, in @1x and @2x flavours.
typeset -a PAIRS=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)
for pair in "${PAIRS[@]}"; do
  SIZE="${pair%%:*}"
  NAME="${pair#*:}"
  sips -s format png -z "$SIZE" "$SIZE" "$BASE" --out "$ICONSET/$NAME" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/SuperClean.icns
print -r -- "wrote Resources/SuperClean.icns"
sips -g pixelWidth -g pixelHeight Resources/SuperClean.icns 2>/dev/null | tail -2

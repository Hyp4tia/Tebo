#!/bin/bash
# Notarize the prepared app and DMG, then generate/verify the signed GitHub update feed.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/release.py notarize "$@"

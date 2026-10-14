#!/bin/bash
# Create a reviewable GitHub draft only from verified release assets.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/release.py draft "$@"

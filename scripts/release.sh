#!/bin/bash
# Prepare a strictly Developer ID-signed release; never falls back to development signing.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/release.py build "$@"

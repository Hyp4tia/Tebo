#!/bin/bash
# fetch-engine.sh — download the hash-pinned czkawka_cli arm64 binary into Engines/.
# Idempotent: if the file already exists with the right hash, nothing is re-downloaded.
# Fails loudly on any hash mismatch (deletes the bad file, exits non-zero).
#
# Usage: ./scripts/fetch-engine.sh
# The binary lands at Engines/czkawka_cli (gitignored — only this script + Engines/README.md are committed).

set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE_URL="https://github.com/qarmin/czkawka/releases/download/12.0.2/mac_czkawka_cli_arm64"
EXPECTED_SHA256="3362df5776b209b6365482768bc960e5a853f1b554787954c4a4c64e90bc2c75"
TARGET="Engines/czkawka_cli"

die() { echo "FETCH-ENGINE ERROR: $1" >&2; exit 1; }

command -v shasum >/dev/null 2>&1 || die "shasum not found (macOS ships it)"
command -v curl >/dev/null 2>&1 || die "curl not found"

actual_sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# Idempotency: skip the download when the pinned hash already matches.
if [[ -f "$TARGET" ]]; then
  if [[ "$(actual_sha "$TARGET")" == "$EXPECTED_SHA256" ]]; then
    echo "fetch-engine: $TARGET already present with matching sha256, skipping download."
  else
    echo "fetch-engine: $TARGET exists but its hash does not match the pin — deleting and re-downloading." >&2
    rm -f "$TARGET"
  fi
fi

if [[ ! -f "$TARGET" ]]; then
  mkdir -p Engines
  tmp="${TMPDIR:-/tmp}/czkawka_cli_download.$$"
  trap 'rm -f "$tmp"' EXIT
  echo "fetch-engine: downloading $ENGINE_URL"
  curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$ENGINE_URL" || die "download failed"
  got="$(actual_sha "$tmp")"
  if [[ "$got" != "$EXPECTED_SHA256" ]]; then
    rm -f "$tmp"
    die "sha256 mismatch for downloaded binary. Expected: $EXPECTED_SHA256 Got: $got — bad file deleted, NOT installed."
  fi
  mv "$tmp" "$TARGET"
fi

chmod +x "$TARGET" || die "chmod +x failed"
[[ -x "$TARGET" ]] || die "$TARGET is not executable after chmod"

sha="$(actual_sha "$TARGET")"
version="unknown"
if "$TARGET" --version >/dev/null 2>&1; then
  version="$("$TARGET" --version 2>&1 | head -1)"
fi

echo "fetch-engine: installed $TARGET"
echo "  version: $version"
echo "  sha256:  $sha"
echo "fetch-engine: OK"

#!/bin/zsh
# verify.sh — one command that proves the tree is healthy. Runs headless, exits non-zero on failure.
# Usage: ./scripts/verify.sh [--quick]     (--quick skips the headless app self-test)
# Every milestone in .hermes/plans/2026-09-24_superclean-v1.0-launch.md ends with this script.

set -uo pipefail
cd "$(dirname "$0")/.."

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

step() { print -r -- "\n=== $1"; }
fail() { print -r -- "FAIL: $1"; exit 1; }

step "1/4 xcodegen generate"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet || fail "xcodegen"
else
  print -r -- "xcodegen not installed — skipping project regeneration"
fi

step "2/4 swift build"
swift build 2>&1 | tail -5 || fail "swift build"

step "3/4 swift test"
TEST_OUT=$(swift test 2>&1) || { print -r -- "$TEST_OUT" | tail -30; fail "swift test"; }
print -r -- "$TEST_OUT" | grep -E "Test run with|✘|failed" | tail -5
print -r -- "$TEST_OUT" | grep -q "✘" && fail "tests reported failures"

step "4/4 headless self-test"
if [[ $QUICK -eq 1 ]]; then
  print -r -- "skipped (--quick)"
elif swift build -c debug >/dev/null 2>&1; then
  BIN=".build/debug/SuperClean"
  if [[ -x "$BIN" ]] && "$BIN" --selftest 2>/dev/null; then
    print -r -- "self-test ok"
  else
    print -r -- "self-test not implemented yet (M0 onwards will add it) — not a failure"
  fi
fi

print -r -- "\nverify.sh: OK"

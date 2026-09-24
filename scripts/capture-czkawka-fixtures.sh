#!/bin/bash
# capture-czkawka-fixtures.sh — regenerate ALL czkawka fixtures in
# Tests/Fixtures/czkawka/ against the real Engines/czkawka_cli binary.
#
# Usage: ./scripts/capture-czkawka-fixtures.sh [fixture-tree-dir]
#   No argument: builds a fresh deterministic tree (scripts/build-fixture-tree.sh)
#   and captures against it. With an argument: captures against that tree.
#
# What this script does:
#   1. Builds (or accepts) the fixture tree.
#   2. Delegates the 12-tool ground-truth capture to scripts/capture-fixtures.sh
#      (dup HASH, empty-folders, empty-files, big, temp, symlinks, broken, ext,
#      bad-names, image, music, video + manifest.json + per-tool .log files).
#   3. Adds three same-name files and captures the three dup search-method variants
#      the reference doc could not confirm from source alone:
#        dup-size.json       -s SIZE      (object keyed by size, FLAT entries, hash "")
#        dup-name.json       -s NAME      (object keyed by name, FLAT entries, hash "")
#        dup-size-name.json  -s SIZE_NAME (bare array of groups, keys dropped by serde)
#   4. Validates every committed JSON parses and keeps the total under 200 KB.
#
# Invariant, same as capture-fixtures.sh: every run passes
#   <tool> -d <tree> -p <json> -N -M -W   and NEVER -D or -y
# (those flags make a scan destructive — SuperClean only finds, never deletes).

set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="Engines/czkawka_cli"
OUT_DIR="Tests/Fixtures/czkawka"

[[ -x "$ENGINE" ]] || { echo "capture-czkawka-fixtures: $ENGINE missing — run scripts/fetch-engine.sh first" >&2; exit 1; }

if [[ $# -ge 1 ]]; then
  TREE="$1"
  [[ -d "$TREE" ]] || { echo "capture-czkawka-fixtures: no fixture tree at $TREE" >&2; exit 1; }
else
  TREE="$(scripts/build-fixture-tree.sh | sed -n 's/^FIXTURE_TREE=//p')"
fi
TREE="$(cd "$TREE" && pwd -P)"
OUT_ABS="$(pwd)/$OUT_DIR"
mkdir -p "$OUT_ABS"

# --- 1. Main ground-truth capture (12 tools, manifest, .log files) -----------------
echo "capture-czkawka-fixtures: capturing the 12-tool set (scripts/capture-fixtures.sh)"
scripts/capture-fixtures.sh "$TREE"

# --- 2. dup search-method variants (shapes the reference doc left unconfirmed) -----
# NAME/SIZE_NAME only report files >8KB (dup default -m 8192), so plant same-name
# files that are big enough. Deterministic python3 payloads, no media tools needed.
python3 - "$TREE" <<'PYEOF'
import os, sys
tree = sys.argv[1]
os.makedirs(f"{tree}/extras/subA", exist_ok=True)
os.makedirs(f"{tree}/extras/subB", exist_ok=True)
def make(path, size, seed):
    line = (seed + "\n").encode()
    with open(path, "wb") as f:
        while size > 0:
            chunk = line[:size]
            f.write(chunk)
            size -= len(chunk)
# Same name + same size (SIZE_NAME group; also a NAME group).
make(f"{tree}/extras/subA/report.txt", 10240, "SuperClean NAME method same-name payload AAAA 0123456789")
make(f"{tree}/extras/subB/report.txt", 10240, "SuperClean NAME method same-name payload AAAA 0123456789")
# Same name + same size, different content (NAME group; SIZE_NAME group by size+name).
make(f"{tree}/extras/subA/other.txt", 12288, "SuperClean NAME diff content CCCC 5555555555")
make(f"{tree}/extras/subB/other.txt", 12288, "SuperClean NAME diff content DDDD 6666666666")
# Same name, DIFFERENT sizes (NAME group only — proves NAME ignores size).
make(f"{tree}/extras/subA/small.bin", 9216, "SuperClean NAME smaller size XXXX")
make(f"{tree}/extras/subB/small.bin", 10240, "SuperClean NAME bigger size YYYY 99")
print("extras written")
PYEOF

variant_method() {
  case "$1" in
    size) echo SIZE ;;
    name) echo NAME ;;
    size-name) echo SIZE_NAME ;;
  esac
}
for variant in size name size-name; do
  method="$(variant_method "$variant")"
  json="$OUT_ABS/dup-$variant.json"
  log="$OUT_ABS/dup-$variant.log"
  rm -f "$json"
  {
    echo "# SuperClean fixture capture $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# cmd: $ENGINE dup -d $TREE -s $method -p $OUT_DIR/dup-$variant.json -N -M -W"
    echo "# (stdout/stderr of the tool follows; empty body = nothing printed thanks to -N -M)"
  } > "$log"
  "$ENGINE" dup -d "$TREE" -s "$method" -p "$json" -N -M -W >>"$log" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "capture-czkawka-fixtures: dup -s $method exited $rc (see $log)" >&2
    exit 1
  fi
  [[ -s "$json" ]] || { echo "capture-czkawka-fixtures: dup -s $method wrote no JSON" >&2; exit 1; }
  echo "capture-czkawka-fixtures: dup-$variant.json  ($(stat -f%z "$json") bytes, rc=$rc)"
done

# --- 3. Validation ------------------------------------------------------------------
python3 - "$OUT_ABS" <<'PYEOF'
import json, os, sys
out = sys.argv[1]
total = 0
problems = []
for name in sorted(os.listdir(out)):
    if not name.endswith(".json"):
        continue
    path = os.path.join(out, name)
    total += os.path.getsize(path)
    try:
        with open(path) as f:
            data = json.load(f)
        kind = type(data).__name__
        detail = f"len={len(data)}" if isinstance(data, (list, dict)) else ""
        print(f"  OK  {name:28s} {kind} {detail}")
    except Exception as exc:
        problems.append(f"{name}: {exc}")
if problems:
    for problem in problems:
        print(f"  FAIL {problem}", file=sys.stderr)
    sys.exit(1)
if total > 200 * 1024:
    print(f"capture-czkawka-fixtures: fixtures total {total} bytes exceeds 200 KB", file=sys.stderr)
    sys.exit(1)
print(f"capture-czkawka-fixtures: OK — {total} bytes total (< 200 KB), tree: {out}")
PYEOF

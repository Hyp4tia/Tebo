#!/bin/bash
# capture-fixtures.sh — run EVERY czkawka tool against the fixture tree and save the
# raw JSON output as ground-truth fixtures for the Swift parsers.
#
# Usage: ./scripts/capture-fixtures.sh [tree-dir]
#   Without an argument: builds a fresh fixture tree (scripts/build-fixture-tree.sh)
#   and captures against it. With an argument: captures against the given tree.
#
# For every tool it writes:
#   Tests/Fixtures/czkawka/<tool>.json   raw pretty JSON from czkawka (-p)
#   Tests/Fixtures/czkawka/<tool>.log    everything the tool printed on stdout/stderr
#   Tests/Fixtures/czkawka/manifest.json exit code + output sizes for every tool
#
# Invariant: every run passes  -d <tree> -p <json> -N -M -W  and NEVER -D or -y
# (those make the scan destructive — SuperClean only finds, never deletes).
#
# bad-names is the one tool that needs check flags: with none of -u -j -w -n -a
# passed, it checks nothing and always returns [] (verified against 12.0.2).

set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="Engines/czkawka_cli"
OUT_DIR="Tests/Fixtures/czkawka"

[[ -x "$ENGINE" ]] || { echo "capture-fixtures: $ENGINE missing — run scripts/fetch-engine.sh first" >&2; exit 1; }

if [[ $# -ge 1 ]]; then
  TREE="$1"
  [[ -d "$TREE" ]] || { echo "capture-fixtures: no fixture tree at $TREE" >&2; exit 1; }
else
  TREE="$(scripts/build-fixture-tree.sh | sed -n 's/^FIXTREE_E=//p;s/^FIXTURE_TREE=//p')"
fi
TREE="$(cd "$TREE" && pwd -P)"
OUT_ABS="$(pwd)/$OUT_DIR"
mkdir -p "$OUT_ABS"

# tool-name => extra args after the common ones. Order matches the task spec.
TOOLS=(dup empty-folders empty-files big temp symlinks broken ext bad-names image music video)
EXTRA_ARGS=("" "" "" "" "" "" "" "" "-u -w" "" "" "")

MANIFEST="$OUT_ABS/manifest.json"
TSV="$OUT_ABS/.manifest.tsv"
: > "$TSV"

failcount=0
for i in "${!TOOLS[@]}"; do
  name="${TOOLS[$i]}"
  extra="${EXTRA_ARGS[$i]}"
  json="$OUT_ABS/$name.json"
  log="$OUT_ABS/$name.log"
  rm -f "$json"

  {
    echo "# SuperClean fixture capture $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# cmd: $ENGINE $name -d $TREE -p $json -N -M -W $extra"
    echo "# (stdout/stderr of the tool follows; empty body = nothing printed thanks to -N -M)"
  } > "$log"

  set +e
  "$ENGINE" "$name" -d "$TREE" -p "$json" -N -M -W $extra >>"$log" 2>&1
  rc=$?
  set -e

  json_bytes=0
  [[ -f "$json" ]] && json_bytes="$(stat -f%z "$json")"
  printf '%s\t%s\t%s\t%s\n' "$name" "$rc" "$json_bytes" "$(stat -f%z "$log")" >> "$TSV"

  if [[ ! -f "$json" || "$json_bytes" -eq 0 ]]; then
    echo "capture-fixtures: WARNING: $name produced no JSON (rc=$rc, see $OUT_DIR/$name.log)" >&2
    failcount=$((failcount + 1))
  fi
done

# Validate every captured JSON parses, and summarize shapes.
python3 - "$TSV" "$MANIFEST" "$OUT_ABS" <<'PYEOF'
import json, os, sys
tsv_path, manifest_path, out_dir = sys.argv[1:4]
manifest = {}
for line in open(tsv_path):
    name, rc, jb, lb = line.rstrip("\n").split("\t")
    entry = {"exit_code": int(rc), "json_bytes": int(jb), "log_bytes": int(lb),
             "json_file": os.path.join(out_dir, name + ".json")}
    p = entry["json_file"]
    if os.path.isfile(p) and int(jb) > 0:
        try:
            with open(p) as f:
                data = json.load(f)
            entry["json_parses"] = True
            entry["top_level_type"] = type(data).__name__
            if isinstance(data, list):
                entry["top_level_len"] = len(data)
            elif isinstance(data, dict):
                entry["top_level_keys"] = sorted(data.keys())
        except Exception as e:
            entry["json_parses"] = False
            entry["parse_error"] = str(e)
    else:
        entry["json_parses"] = False
    manifest[name] = entry
    print(f"{name}: rc={rc} json_bytes={jb} log_bytes={lb} "
          f"{('parses: '+entry.get('top_level_type','')+' len='+str(entry.get('top_level_len', entry.get('top_level_keys','')))) if entry.get('json_parses') else 'NO JSON/UNPARSEABLE'}")
with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF
rm -f "$TSV"

if [[ $failcount -gt 0 ]]; then
  echo "capture-fixtures: $failcount tool(s) produced no JSON — check the .log files" >&2
  exit 1
fi
echo "capture-fixtures: OK — fixtures in $OUT_ABS (tree: $TREE)"

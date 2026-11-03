#!/bin/bash
# L2 dump evidence: the A2, A14, A16 and R10 scenario dumps (L1-dumps.sh's set) against one
# checkout, each into <out dir>/<name>/ plus a log. `main` runs the dumps as they are; `branch`
# runs L2-A2-/L2-A14-scenario_dump.gd, the same scripts with their tile arguments ported to
# Vector3i (A16 and R10 run unchanged). Then L2-compare_dumps.py compares the two trees.
# Usage: bash docs/orca/handoffs/L2-dumps.sh <checkout root> <out dir> main|branch  (Godot from $GODOT)
# Exits non-zero when any dump does.
set -u
handoffs="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || pwd)"
failed=0
for d in A2 A14 A16 R10; do
  script="$d-scenario_dump.gd"
  if [ "$3" = "branch" ] && [ -f "$handoffs/L2-$d-scenario_dump.gd" ]; then script="L2-$d-scenario_dump.gd"; fi
  mkdir -p "$2/$d"
  "$GODOT" --headless --path "$1/game" --script "$handoffs/$script" -- "$2/$d" > "$2/$d.log" 2>&1
  code=$?
  echo "$d ($script) exit $code"
  [ "$code" -eq 0 ] || failed=1
done
exit "$failed"

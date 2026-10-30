#!/bin/bash
# L1 byte-identity evidence: runs the existing A2, A14, A16 and R10 scenario dumps (all in this
# folder, unchanged) against one checkout and writes each into <out dir>/<name>/ plus a log.
# Run once against a main worktree and once against the L1 branch, then `diff -r -q` the two.
# Usage: bash docs/orca/handoffs/L1-dumps.sh <checkout root> <out dir>   (Godot from $GODOT)
set -u
handoffs="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || pwd)"
for d in A2 A14 A16 R10; do
  mkdir -p "$2/$d"
  "$GODOT" --headless --path "$1/game" --script "$handoffs/$d-scenario_dump.gd" -- "$2/$d" > "$2/$d.log" 2>&1
  echo "$d exit $?"
done

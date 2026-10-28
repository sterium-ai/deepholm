#!/bin/bash
# R16 evidence. Usage (repo root, Git Bash): bash docs/orca/handoffs/R16-probes.sh <scratch-dir>
# <scratch-dir>/base must hold `git archive <base> game` extracted. Prints "<probe>: N of M files differ".
# Usage: probes.sh <scratch> ; runs each probe on the base archive and the branch, then compares.
S="$1"; R="$(pwd)"; G="$(powershell -NoProfile -Command '[Environment]::GetEnvironmentVariable("GODOT","User")' | tr -d '\r')"
"$G" --headless --path "$S/base/game" --import >/dev/null 2>&1
"$G" --headless --path game --import >/dev/null 2>&1
for p in R5 R6 R8 R9 R10 A14 A16; do
  rm -rf "$S/out/$p"; mkdir -p "$S/out/$p/before" "$S/out/$p/after"
  "$G" --headless --path "$S/base/game" --script "$R/docs/orca/handoffs/$p-scenario_dump.gd" -- "$S/out/$p/before" > "$S/out/$p/before.log" 2>&1
  "$G" --headless --path game --script "$R/docs/orca/handoffs/$p-scenario_dump.gd" -- "$S/out/$p/after" > "$S/out/$p/after.log" 2>&1
  n=$(ls "$S/out/$p/before" | wc -l); d=0
  for f in "$S/out/$p/before"/*; do cmp -s "$f" "$S/out/$p/after/$(basename "$f")" || d=$((d+1)); done
  echo "$p: $d of $n files differ | $(grep -h '^scenario_dump:' "$S/out/$p/after.log" | head -1 | grep -o 'hash=[0-9]*')"
done

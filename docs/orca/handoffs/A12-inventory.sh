#!/usr/bin/env bash
# Reproduces the coordinate inventory quoted in ADR 044 and handoffs/A12.md.
# Usage (Git Bash, repo root): bash docs/orca/handoffs/A12-inventory.sh
set -eu
core=game/scripts/core
echo "Vector2i occurrences in core: $(grep -o Vector2i -r $core --include=*.gd | wc -l)"
for d in $core/*/; do
	n=$(grep -o Vector2i -r "$d" --include=*.gd | wc -l)
	if [ "$n" -gt 0 ]; then echo "  $(basename "$d")/: $n"; fi
done
echo "  world_state.gd: $(grep -o Vector2i $core/world_state.gd | wc -l)"
echo "Vector2i in viewer + boot.gd: $(grep -o Vector2i -r game/scripts/viewer game/scripts/boot.gd --include=*.gd | wc -l)"
echo "String tile key formats in core (occurrences):"
grep -rho --include=*.gd -E '"%d_%d"|"tile:%d,%d"|"cell:%d,%d"|"%s%d,%d"|"%d,%d"' $core | sort | uniq -c
grep -n 'TARGET_KEY_PREFIX :=' $core/jobs/job_queue.gd
echo "row-major index math (y * width + x):"
grep -rn --include=*.gd -E 'y \* _?width \+ x' $core
echo "[\"x\"] reads in core: $(grep -rn --include=*.gd '\["x"\]' $core | wc -l)"
echo "planar distance lines (absi/abs on .x): $(grep -rn --include=*.gd -E 'abs\(.*\.x|maxi\(absi|absi\(' $core | wc -l)"
echo "  in files: $(grep -rln --include=*.gd 'absi(' $core | wc -l)"

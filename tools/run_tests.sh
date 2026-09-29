#!/usr/bin/env bash
# Runs every game/scripts/tests/test_*.gd script through Godot headless.
# A test passes when the process exits 0 and prints "<test_name>: PASS".
# Usage: tools/run_tests.sh [path-to-godot]   (defaults to $GODOT or "godot")
set -u
GODOT="${1:-${GODOT:-godot}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="$REPO_ROOT/game"
TESTS_DIR="$GAME_DIR/scripts/tests"

shopt -s nullglob
tests=("$TESTS_DIR"/test_*.gd)
if [ ${#tests[@]} -eq 0 ]; then
  echo "run_tests: no test_*.gd files found" >&2
  exit 1
fi

failures=()
for path in "${tests[@]}"; do
  file="$(basename "$path")"
  name="${file%.gd}"
  echo "=== Running $name ==="
  output="$("$GODOT" --headless --path "$GAME_DIR" --script "res://scripts/tests/$file" 2>&1)"
  code=$?
  echo "$output"
  if [ $code -ne 0 ] || ! grep -qF "${name}: PASS" <<<"$output"; then
    echo "=== FAILED: $name (exit code $code) ==="
    failures+=("$name")
  fi
done

if [ ${#failures[@]} -gt 0 ]; then
  echo "run_tests: ${#failures[@]} of ${#tests[@]} test(s) failed: ${failures[*]}" >&2
  exit 1
fi
echo "run_tests: all ${#tests[@]} test(s) PASS"

"""A13 evidence: the JSON reader/parser moved from content_registry.gd to content_json.gd unchanged.

Compares main's content_registry.gd, from `func _read_json` through `_json_parse_null`, with
content_json.gd below its header. The only allowed differences are the `static ` prefix on each
`func` and the two public names (`_read_json` -> `read_json`, `_parse_json` -> `parse_json`).
Run from the repo root:  python docs/orca/handoffs/A13-move_check.py [base-ref]   (default main)
"""
import subprocess
import sys

base = sys.argv[1] if len(sys.argv) > 1 else "main"
old = subprocess.run(["git", "show", f"{base}:game/scripts/core/content/content_registry.gd"],
                     capture_output=True, text=True, encoding="utf-8", check=True).stdout.split("\n")
start = old.index("func _read_json(path: String) -> Dictionary:")
end = next(i for i in range(start, len(old)) if old[i].startswith("func _json_parse_null"))
end = next(i for i in range(end + 1, len(old)) if old[i] == "")
moved = old[start:end]

new = open("game/scripts/core/content/content_json.gd", encoding="utf-8").read().split("\n")
new_start = new.index("static func read_json(path: String) -> Dictionary:")
body = new[new_start:]
while body and body[-1] == "":
    body.pop()


def normalise(line: str) -> str:
    if line.startswith("static func "):
        line = line[len("static "):]
    return line.replace("func read_json(", "func _read_json(").replace("func parse_json(", "func _parse_json(") \
        .replace("parse_json(text)", "_parse_json(text)").replace("__parse_json", "_parse_json")


normalised = [normalise(line) for line in body]
if normalised == moved:
    print(f"A13 move check: OK, {len(moved)} lines moved unchanged (static prefix and 2 renames only)")
    sys.exit(0)
for i, (a, b) in enumerate(zip(moved, normalised)):
    if a != b:
        print(f"first difference at moved line {i + 1}:\n  main:   {a!r}\n  branch: {b!r}")
        break
print(f"A13 move check: FAIL ({len(moved)} lines on {base}, {len(normalised)} in content_json.gd)")
sys.exit(1)

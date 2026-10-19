"""Rewrites test reads/writes of WorldState's moved item fields to world._item_table.*.
Mechanical: only the receiver path changes, never an assertion. Usage: python docs/orca/handoffs/R2-retarget_tests.py game/scripts/tests (already applied on the branch)"""
import re, sys, pathlib

# (?<![A-Za-z]) on the receiver prefix keeps "WorldState._x" doc references untouched.
RULES = [
    (r"\._items\b", "._item_table.items"),
    (r"\._next_item_id\b", "._item_table.next_item_id"),
    (r"\._item_factions\b", "._item_table.item_factions"),
    (r"\._ground_berries\b", "._item_table.ground_berries"),
    (r"\._pending_dig_finds\b", "._item_table.pending_dig_finds"),
    (r"\._dig_find_random\b", "._item_table.dig_find_random"),
    (r"\._dig_item_placement\(", "._item_table.dig_item_placement("),
    (r"\._resolve_dig_finds\(", "._item_table.resolve_dig_finds("),
    (r"\._spawn_wood_item\(", "._item_table.spawn_wood_item("),
    (r"\._spawn_stone_item\(", "._item_table.spawn_stone_item("),
    (r"\._spawn_berries_item\(", "._item_table.spawn_berries_item("),
    (r"\._spawn_item\(", "._item_table.spawn_item("),
]
RECEIVER = r"(?<![A-Za-z_])(world|restored|world_a|world_b|carry_world|live|loaded)"

changed = {}
for path in sorted(pathlib.Path(sys.argv[1]).glob("test_*.gd")):
    text = path.read_bytes().decode("utf-8")
    new = text
    for pattern, repl in RULES:
        new = re.sub(RECEIVER + pattern, lambda m, r=repl: m.group(1) + r, new)
    if new != text:
        path.write_bytes(new.encode("utf-8"))
        changed[path.name] = sum(1 for a, b in zip(text.splitlines(), new.splitlines()) if a != b)
for name, n in changed.items():
    print(f"{name}: {n} line(s)")
print(f"{len(changed)} file(s), {sum(changed.values())} line(s)")

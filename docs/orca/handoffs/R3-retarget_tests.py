"""R3: retargets tests from WorldState's moved private members to their new owner.

Receiver renames only (`world._tiles` -> `world._tile_grid.tiles`, ...): every
rewrite is a `.` + old name -> `.` + new owner path, so `--check` can undo the
mapping on each changed file and compare it byte-for-byte with `main`.

Usage (repo root):
    python docs/orca/handoffs/R3-retarget_tests.py          # apply
    python docs/orca/handoffs/R3-retarget_tests.py --check  # verify against main
"""
import glob
import re
import subprocess
import sys

# (old member after ".", new member path after "."). Order matters only for --check's inverse.
MAP = [
    ("_tiles", "_tile_grid.tiles"),
    ("_tile_index", "_tile_grid.tile_index"),
    ("_dirty_cells", "_tile_grid.dirty_cells"),
    ("_water_tile_cache", "_tile_grid.water_tile_cache"),
    ("_get_water_tiles", "_tile_grid.get_water_tiles"),
    ("_get_regions", "_tile_grid.get_regions"),
    ("_objects", "_object_table.objects"),
    ("_object_factions", "_object_table.object_factions"),
    ("_object_health_at", "_object_table.object_health_at"),
    ("_object_health", "_object_table.object_health"),
    ("_set_object", "_object_table.set_object"),
    ("_damage_object", "_object_table.damage_object"),
    ("_zones", "_zone_table.zones"),
    ("_is_passable", "_passability.is_passable"),
    ("_region_reachable", "_passability.region_reachable"),
]
TESTS = "game/scripts/tests"


def forward(text):
    for old, new in MAP:
        text = re.sub(r"\." + re.escape(old) + r"\b", "." + new, text)
    return text


def inverse(text):
    for old, new in MAP:
        text = re.sub(r"\." + re.escape(new) + r"\b", "." + old, text)
    return text


def main():
    if "--check" in sys.argv:
        changed = subprocess.run(["git", "diff", "--name-only", "main", "--", TESTS],
                                 capture_output=True, text=True, check=True).stdout.split()
        bad = 0
        for path in changed:
            cur = open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")
            base = subprocess.run(["git", "show", "main:" + path], capture_output=True, check=True).stdout
            base = base.decode("utf-8").replace("\r\n", "\n")
            ok = inverse(cur) == base
            bad += not ok
            print(path, "OK" if ok else "DIFFERS")
        print("retarget_check: %d file(s), %d differ" % (len(changed), bad))
        sys.exit(1 if bad else 0)
    count = 0
    for path in sorted(glob.glob(TESTS + "/test_*.gd")):
        raw = open(path, encoding="utf-8", newline="").read()
        new = forward(raw)
        if new != raw:
            open(path, "w", encoding="utf-8", newline="").write(new)
            count += 1
    print("retargeted %d file(s)" % count)


if __name__ == "__main__":
    main()

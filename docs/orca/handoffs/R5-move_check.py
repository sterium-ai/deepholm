"""R5: checks that every function moved from WorldState into ConstructionSystem is a move.

For each moved function it takes the body from `main`'s world_state.gd, applies the
mechanical renames below (new names, injected Callables, sibling-module receivers),
and compares it, statement by statement with comment lines and blank lines dropped,
with the body now in objects/construction_system.gd. `--emit` prints the renamed
bodies instead (how the module's code was first generated).

Usage (repo root):
    python docs/orca/handoffs/R5-move_check.py [base-ref]          # default base: main
    python docs/orca/handoffs/R5-move_check.py --emit [base-ref]
"""
import re
import subprocess
import sys

OLD_PATH = "game/scripts/core/world_state.gd"
NEW_PATH = "game/scripts/core/objects/construction_system.gd"

# old name in WorldState -> name in ConstructionSystem (public ones lose the "_").
MOVED = [
    ("_apply_construction_submission", "apply_construction_submission"),
    ("_check_construction_command", "check_construction_command"),
    ("_construction_footprint_check", "_construction_footprint_check"),
    ("_classify_build_line_command", "classify_build_line_command"),
    ("_apply_build_line_command", "apply_build_line_command"),
    ("_build_site_terrain_valid", "_build_site_terrain_valid"),
    ("_build_site_key", "_build_site_key"),
    ("_public_site_view", "_public_site_view"),
    ("get_construction_sites", "get_construction_sites"),
    ("get_construction_site", "get_construction_site"),
    ("_construction_site_id_at", "construction_site_id_at"),
    ("_construction_site_exists", "construction_site_exists"),
    ("_construction_site_deposit", "construction_site_deposit"),
    ("_construction_item_reservation_owner", "construction_item_reservation_owner"),
    ("_pending_site_fetch_jobs", "_pending_site_fetch_jobs"),
    ("_next_site_fetch_source", "next_site_fetch_source"),
    ("_reachable_short_sibling_sites", "reachable_short_sibling_sites"),
    ("_site_fetch_work_busy", "_site_fetch_work_busy"),
    ("_next_site_fetch_site", "next_site_fetch_site"),
    ("_active_site_fetch_job_ids", "active_site_fetch_job_ids"),
    ("_resolve_freshly_activated_site_fetch_sources", "resolve_freshly_activated_site_fetch_sources"),
    ("_submit_site_fetch", "submit_site_fetch"),
    ("_submit_site_work", "submit_site_work"),
    ("_nearest_free_adjacent_to_footprint", "_nearest_free_adjacent_to_footprint"),
    ("_cancel_construction_site", "cancel_construction_site"),
    ("_finalize_construction_site", "_finalize_construction_site"),
    ("_release_site_builder", "release_site_builder"),
    ("_would_enclose_tiles", "_would_enclose_tiles"),
    ("_flood_fill_passable", "_flood_fill_passable"),
]

# Applied in order to every old body after the function-name renames.
RENAMES = [
    (r"\b_sites\b", "site_table"),
    (r"\b_site_fetch_source_retargeted\b", "site_fetch_source_retargeted"),
    (r"var colonist := _find_job_colonist\(", "var colonist: Dictionary = _find_job_colonist.call("),
    (r"var cost := _route_cost\(", "var cost: int = _route_cost.call("),
    (r"\b_colonist_at\(", "_colonist_at.call("),
    (r"\b_finish_job\(", "_finish_job.call("),
    (r"\b_drop_carried_haul_item\(", "_drop_carried_haul_item.call("),
    (r"(?<![\w.])get_object\(", "_object_table.get_object("),
    (r"(?<![\w.])get_tile\(", "_tile_grid.get_tile("),
    (r"(?<![\w.])passability\(", "_passability.passability("),
    (r"\bin _colonists:", "in _get_colonists.call():"),
]


def git_show(ref, path):
    return subprocess.run(["git", "show", "%s:%s" % (ref, path)], capture_output=True,
                          check=True).stdout.decode("utf-8").replace("\r\n", "\n")


def body(lines, name):
    starts = [k for k, l in enumerate(lines) if l.startswith("func %s(" % name)]
    if len(starts) != 1:
        return None
    i = starts[0]
    j = i + 1
    while j < len(lines) and (lines[j].startswith("\t") or lines[j] == ""):
        j += 1
    while lines[j - 1] == "":
        j -= 1
    return lines[i:j]


def rename(text):
    for old, new in MOVED:
        if old != new:
            text = re.sub(r"(?<![\w.])" + re.escape(old) + r"\(", new + "(", text)
    for pattern, repl in RENAMES:
        text = re.sub(pattern, repl, text)
    return text


def code_only(lines):
    return [l.rstrip() for l in lines if l.strip() and not l.strip().startswith("#")]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    base = args[0] if args else "main"
    old_lines = git_show(base, OLD_PATH).split("\n")
    if "--emit" in sys.argv:
        for old, _new in MOVED:
            print(rename("\n".join(body(old_lines, old))) + "\n")
        return
    new_lines = open(NEW_PATH, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    cur_lines = open(OLD_PATH, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    bad = 0
    for old, new in MOVED:
        expected = code_only(rename("\n".join(body(old_lines, old))).split("\n"))
        got = body(new_lines, new)
        still_there = body(cur_lines, old) is not None
        ok = got is not None and code_only(got) == expected
        bad += not ok
        print("%-48s -> %-46s %s%s" % (old, new, "OK" if ok else "DIFFERS",
                                        "  (old name still defined in WorldState)" if still_there else ""))
    print("move_check: %d function(s), %d differ" % (len(MOVED), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

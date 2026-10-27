"""R11: checks that every function moved from WorldState into ToilBindings is a move.

For each moved function it takes the body from the base's world_state.gd, applies the
mechanical renames below (new names, injected Callables, sibling-module receivers), and
compares it, statement by statement with comment lines and blank lines dropped, with the
body now in jobs/toil_bindings.gd (signature line included).

No statement is added or dropped by the move.

Usage (repo root):
    python docs/orca/handoffs/R11-move_check.py [base-ref]          # default base: main
    python docs/orca/handoffs/R11-move_check.py --emit [base-ref]   # print renamed bodies
"""
import re
import subprocess
import sys

OLD_PATH = "game/scripts/core/world_state.gd"
NEW_PATH = "game/scripts/core/jobs/toil_bindings.gd"

# old name in WorldState -> name in ToilBindings (called from outside: public, no "_").
MOVED = [
    ("_drop_carried_item_from", "drop_carried_item_from"),
    ("_deposit_carried_item", "_deposit_carried_item"),
    ("_force_drop_carried_item", "_force_drop_carried_item"),
    ("_drop_carried_haul_item", "drop_carried_haul_item"),
    ("_terminate_haul_job_by_id", "terminate_haul_job_by_id"),
    ("_work_target_for", "work_target_for"),
    ("_toil_no_op_arrive", "toil_no_op_arrive"),
    ("_toil_go_to_target", "_toil_go_to_target"),
    ("_toil_is_first_leg", "_toil_is_first_leg"),
    ("_toil_go_to_passable", "_toil_go_to_passable"),
    ("_toil_go_to_force_trim_last", "_toil_go_to_force_trim_last"),
    ("_toil_go_to_skip_assignment_path", "_toil_go_to_skip_assignment_path"),
    ("_toil_on_unreachable", "toil_on_unreachable"),
    ("_toil_item_id_for", "_toil_item_id_for"),
    ("_toil_cell_for", "_toil_cell_for"),
    ("_toil_site_id_for", "_toil_site_id_for"),
    ("_toil_pick_up_count_for", "_toil_pick_up_count_for"),
    ("_toil_on_pick_up_success", "_toil_on_pick_up_success"),
    ("_toil_on_toil_fail", "_toil_on_toil_fail"),
    ("_toil_on_place_success", "_toil_on_place_success"),
    ("_toil_on_deposit_success", "_toil_on_deposit_success"),
    ("_toil_on_work_complete", "_toil_on_work_complete"),
    ("_resolve_giver_association", "resolve_giver_association"),
    ("_toil_on_consume_success", "_toil_on_consume_success"),
    ("_toil_on_no_tool_found", "_toil_on_no_tool_found"),
    ("_tool_exists", "tool_exists"),
    ("_tool_requirement_for_kind", "tool_requirement_for_kind"),
]

# Applied in order to every old body after the function-name renames.
RENAMES = [
    # one-line WorldState delegations -> the sibling-module methods they delegated to
    (r"(?<![\w.])get_tile\(", "_tile_grid.get_tile("),
    (r"(?<![\w.])get_tool_items\(\)", "_tool_store.get_items()"),
    (r"(?<![\w.])get_tool_item_reservation,", "_tool_store.reservation_of,"),
    (r"(?<![\w.])_get_job\(", "_scheduler.queue.get_job("),
    # injected Callables
    (r"(?<![\w.])(_finish_job|_find_job_colonist|_find_colonist|_resubmit_unreachable_job"
     r"|_routable_to|_route_cost)\(", r"\1.call("),
    # a Callable returns Variant, so `:=` cannot infer: the declared type is spelled out
    (r"var (\w+) := ((_find_job_colonist|_find_colonist)\.call\()", r"var \1: Dictionary = \2"),
    (r"var (\w+) := (_route_cost\.call\()", r"var \1: int = \2"),
    (r"_need_giver\.resolve_job\(", "_need_giver_resolve_job.call("),
    (r"_rescue_giver\.resolve_job\(", "_rescue_giver_resolve_job.call("),
    # the roster arrives as a lambda
    (r"\b_colonists\b", "_get_colonists.call()"),
]


def git_show(ref, path):
    return subprocess.run(["git", "show", "%s:%s" % (ref, path)], capture_output=True,
                          check=True).stdout.decode("utf-8").replace("\r\n", "\n")


def body(lines, name):
    starts = [k for k, l in enumerate(lines) if re.match(r"(static )?func %s\(" % re.escape(name), l)]
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
    for old, n in MOVED:
        if old != n:
            text = re.sub(r"(?<![\w.])" + re.escape(old) + r"\b", n, text)
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
        for old, new in MOVED:
            print(rename("\n".join(body(old_lines, old))) + "\n")
        return
    new_lines = open(NEW_PATH, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    cur_lines = open(OLD_PATH, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    bad = 0
    for old, new in MOVED:
        expected = code_only(rename("\n".join(body(old_lines, old))).split("\n"))
        got = body(new_lines, new)
        ok = got is not None and code_only(got) == expected
        bad += not ok
        still_there = body(cur_lines, old) is not None
        print("%-34s -> %-34s %s%s" % (old, new, "OK" if ok else "DIFFERS",
                                        "  (WorldState keeps a delegation)" if still_there else ""))
    print("move_check: %d function(s), %d differ" % (len(MOVED), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

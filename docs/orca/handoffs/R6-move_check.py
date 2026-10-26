"""R6: checks that every function moved from WorldState into TrenchSystem is a move.

For each moved function it takes the body from `main`'s world_state.gd, applies the
mechanical renames below (new names, injected Callables, sibling-module receivers),
and compares it, statement by statement with comment lines and blank lines dropped,
with the body now in actors/trench_system.gd.

Four statement blocks were lifted out of WorldState functions that stay (other tasks own
them) into new TrenchSystem helpers. For those, EXTRACTS names the block in `main`
(first and last statement, matched after the renames) and how the helper's own statements
map onto it (`return true` stands for the block's `return`, a trailing `return false` is added); the block is compared
with indentation ignored.

`--emit` prints the renamed bodies instead (how the module's code was first generated).

Usage (repo root):
    python docs/orca/handoffs/R6-move_check.py [base-ref]          # default base: main
    python docs/orca/handoffs/R6-move_check.py --emit [base-ref]
"""
import re
import subprocess
import sys

OLD_PATH = "game/scripts/core/world_state.gd"
NEW_PATH = "game/scripts/core/actors/trench_system.gd"

# old name in WorldState -> name in TrenchSystem (called from outside: public, no "_").
MOVED = [
    ("_rescue_candidates", "rescue_candidates"),
    ("_trapped_rescue_victims", "trapped_rescue_victims"),
    ("get_colonist_rescue_reason", "get_colonist_rescue_reason"),
    ("_set_rescue_reason", "set_rescue_reason"),
    ("_rescue_target_candidates", "rescue_target_candidates"),
    ("_trench_exit_tile", "_trench_exit_tile"),
    ("_escaping_actor_at", "_escaping_actor_at"),
    ("_rescue_activation_safe", "rescue_activation_safe"),
    ("_retire_rescue_job", "retire_rescue_job"),
    ("_check_trench_arrival", "check_trench_arrival"),
    ("_actor_traps_on_trench", "_actor_traps_on_trench"),
    ("_trap_actor", "_trap_actor"),
    ("_submit_trench_escape", "_submit_trench_escape"),
    ("_activate_pending_escapes", "activate_pending_escapes"),
    ("_trench_climb_ticks", "_trench_climb_ticks"),
    ("_rescue_routable_to", "rescue_routable_to"),
    ("_is_trench_tile", "is_trench_tile"),
    ("_rescue_victim_for_job", "_rescue_victim_for_job"),
]

# Applied in order to every old body after the function-name renames.
RENAMES = [
    (r"\b_rescue_status\b", "rescue_status"),
    (r"\b_trap_tile_before\b", "trap_tile_before"),
    (r"_rescue_giver\.resolve_job\(", "_resolve_rescue_job.call("),
    (r"var victim_id := _rescue_giver\.victim_for_job\(", "var victim_id: String = _rescue_victim_id_for_job.call("),
    (r"var searching := _need_giver\.searching_colonist_ids\(\)", "var searching: Array[String] = _need_searching_ids.call()"),
    (r"_need_giver\.get_pending_assignments\(\)", "_need_pending_assignments.call()"),
    (r"_combat_giver\.owns\(", "_combat_owns.call("),
    (r"var (\w+) := _find_job_colonist\(", r"var \1: Dictionary = _find_job_colonist.call("),
    (r"\b_find_job_colonist\(", "_find_job_colonist.call("),
    (r"var (\w+) := _find_colonist\(", r"var \1: Dictionary = _find_colonist.call("),
    (r"\b_find_colonist\(", "_find_colonist.call("),
    (r"\b_finish_job\(", "_finish_job.call("),
    (r"\b_drop_carried_haul_item\(", "_drop_carried_haul_item.call("),
    (r"\b_resolve_giver_association\(", "_resolve_giver_association.call("),
    (r"\b_set_work_progress\(", "_set_work_progress.call("),
    (r"(?<![\w.])get_tile\(", "_tile_grid.get_tile("),
    (r"(?<![\w.])passability\(", "_passability.passability("),
    (r"\bin _colonists:", "in _get_colonists.call():"),
]

# (new helper, WorldState function it came from, first statement, last statement,
#  helper statement -> the block statement it stands for, or None when the helper adds it)
EXTRACTS = [
    ("trap_on_work_complete", "_toil_on_work_complete",
     'if String(job.get("kind", "")) != "escape_trench"', "return",
     {"return true": "return", "return false": None}),
    ("mirror_climb_ticks", "_set_work_progress",
     "var escaping := _escaping_actor_at(target)", '(escaping["trapped"] as Dictionary)["ticksRemaining"] = ticks_remaining',
     {}),
    ("complete_escape", "_toil_on_work_complete",
     "var actor := _find_job_colonist(job_id)", "_submit_trench_escape(actor, target)",
     {}),
    ("complete_rescue", "_toil_on_work_complete",
     "var rescuer := _find_job_colonist(job_id)", 'victim["trapped"] = null',
     {}),
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


def block(lines, first, last):
    """Statements from the first line starting with `first` to the next one equal to `last`."""
    code = [l.strip() for l in code_only(lines)]
    i = next(k for k, l in enumerate(code) if l.startswith(rename(first)))
    j = next(k for k in range(i, len(code)) if code[k] == rename(last))
    return code[i:j + 1]


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
        print("%-30s -> %-30s %s%s" % (old, new, "OK" if ok else "DIFFERS",
                                        "  (old name still defined in WorldState)" if still_there else ""))
    for new, old_func, first, last, mapped in EXTRACTS:
        old_body = rename("\n".join(body(old_lines, old_func))).split("\n")
        expected = block(old_body, first, last)
        got = body(new_lines, new)
        got_code = [l.strip() for l in code_only(got[1:])] if got else None
        if got_code is not None:
            got_code = [mapped.get(l, l) for l in got_code]
            got_code = [l for l in got_code if l is not None]
        ok = got_code == expected
        bad += not ok
        print("%-30s -> %-30s %s" % ("block of " + old_func, new, "OK" if ok else "DIFFERS"))
    print("move_check: %d function(s) + %d block(s), %d differ" % (len(MOVED), len(EXTRACTS), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

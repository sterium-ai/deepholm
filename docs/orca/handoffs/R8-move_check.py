"""R8: checks that every function moved from WorldState into NeedsSystem is a move.

For each moved function it takes the body from `main`'s world_state.gd, applies the
mechanical renames below (new names, injected Callables, sibling-module receivers),
and compares it, statement by statement with comment lines and blank lines dropped,
with the body now in actors/needs_system.gd.

The only statement the module adds is ensure_needs()'s first line, which binds the
colonist roster lambda to a local (`colonists[i] = colonist` cannot assign through a
Callable result); ADDED lists it.

`--emit` prints the renamed bodies instead (how the module's code was first generated).

Usage (repo root):
    python docs/orca/handoffs/R8-move_check.py [base-ref]          # default base: main
    python docs/orca/handoffs/R8-move_check.py --emit [base-ref]
"""
import re
import subprocess
import sys

OLD_PATH = "game/scripts/core/world_state.gd"
NEW_PATH = "game/scripts/core/actors/needs_system.gd"

# old name in WorldState -> name in NeedsSystem (called from outside: public, no "_").
MOVED = [
    ("get_colonist_need_reason", "get_colonist_need_reason"),
    ("_needs", "_needs"),
    ("_ensure_needs", "ensure_needs"),
    ("_decay_needs", "decay_needs"),
    ("_pause_work_job", "pause_work_job"),
    ("_resume_paused_job", "resume_paused_job"),
    ("_resume_paused_rescue", "_resume_paused_rescue"),
    ("_interrupt_current_job", "interrupt_current_job"),
    ("_resume_interrupted_job", "resume_interrupted_job"),
    ("_set_need_reason", "set_need_reason"),
    ("_emit_need_unmet_event", "emit_need_unmet_event"),
    ("_need_source_candidates", "need_source_candidates"),
    ("_reachable_candidates_only", "_reachable_candidates_only"),
    ("_need_job_targets", "need_job_targets"),
    ("_need_kind_for_job", "need_kind_for_job"),
    ("_consume_source_valid", "consume_source_valid"),
    ("_apply_need_effect", "apply_need_effect"),
    ("_full_needs", "_full_needs"),
]

# Applied in order to every old body after the function-name renames.
RENAMES = [
    (r"\b_need_status\b", "need_status"),
    (r"\b_paused_jobs\b", "paused_jobs"),
    # one-line WorldState delegations -> the call they delegated to
    (r"(?<![\w.])_get_job\(", "_scheduler.queue.get_job("),
    (r"(?<![\w.])get_ground_berries\(", "_item_table.get_ground_berries("),
    (r"(?<![\w.])get_tile\(", "_tile_grid.get_tile("),
    (r"(?<![\w.])get_object\(", "_object_table.get_object("),
    (r"(?<![\w.])get_room_at\(", "_tile_grid.get_room_at("),
    # injected Callables (typed where GDScript cannot infer from Callable.call())
    (r"var (\w+) := _find_colonist\(", r"var \1: Dictionary = _find_colonist.call("),
    (r"var (\w+) := _default_labour_table\(", r"var \1: Dictionary = _default_labour_table.call("),
    (r"(?<![\w.])(_route|_labour_table|_ensure_health|_ensure_combat|_colonist_within_reach|_advance_go_to_or_resubmit)\(",
     r"\1.call("),
    (r"_combat_giver\.owns\(", "_combat_owns.call("),
    (r"\bPRIORITY_TICK\b", "_event_priority"),
    # the roster arrives as a lambda
    (r"\bin _colonists:", "in _get_colonists.call():"),
    (r"\b_colonists\.(is_empty|any)\(", r"_get_colonists.call().\1("),
    (r"\b_colonists\b", "colonists"),
]

ADDED = {"ensure_needs": ["\tvar colonists: Array[Dictionary] = _get_colonists.call()"]}


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
        got_code = code_only(got) if got is not None else None
        if got_code is not None:
            for added in ADDED.get(new, []):
                if added in got_code:
                    got_code.remove(added)
        still_there = body(cur_lines, old) is not None
        ok = got_code == expected
        bad += not ok
        print("%-30s -> %-30s %s%s" % (old, new, "OK" if ok else "DIFFERS",
                                        "  (old name still defined in WorldState)" if still_there else ""))
    print("move_check: %d function(s), %d differ" % (len(MOVED), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

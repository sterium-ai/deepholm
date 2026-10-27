"""R9: checks that every function moved from WorldState into CombatSystem is a move.

For each moved function it takes the body from the base's world_state.gd (signature line
excluded: the two backfills became static and take colonists/content as parameters, see
SIGNATURES), applies the mechanical renames below (new names, injected Callables,
sibling-module receivers), and compares it, statement by statement with comment lines and
blank lines dropped, with the body now in actors/combat_system.gd.

No statement is added or dropped by the move.

Usage (repo root):
    python docs/orca/handoffs/R9-move_check.py [base-ref]          # default base: main
    python docs/orca/handoffs/R9-move_check.py --emit [base-ref]   # print renamed bodies
"""
import re
import subprocess
import sys

OLD_PATH = "game/scripts/core/world_state.gd"
NEW_PATH = "game/scripts/core/actors/combat_system.gd"

# old name in WorldState -> name in CombatSystem (called from outside: public, no "_").
MOVED = [
    ("_ensure_health", "ensure_health"),
    ("_ensure_combat", "ensure_combat"),
    ("_apply_combat", "apply_combat"),
    ("get_actor_combat_reason", "get_actor_combat_reason"),
    ("_apply_actor_death", "apply_actor_death"),
    ("_cleanup_actor_scheduling", "cleanup_actor_scheduling"),
    ("_cancel_job_for_death", "_cancel_job_for_death"),
    ("_drop_inventory_contents", "_drop_inventory_contents"),
    ("_drop_inventory_item", "_drop_inventory_item"),
    ("get_actors_with_health", "get_actors_with_health"),
]

# The expected new signature line of every moved function.
SIGNATURES = {
    "ensure_health": "static func ensure_health(colonists: Array[Dictionary], content: ContentRegistryType) -> void:",
    "ensure_combat": "static func ensure_combat(colonists: Array[Dictionary], content: ContentRegistryType) -> void:",
}

# The static backfills read their parameters instead of WorldState's fields.
STATIC_RENAMES = [
    (r"\b_colonists\b", "colonists"),
    (r"\b_content\b", "content"),
]

# Applied in order to every other old body after the function-name renames.
RENAMES = [
    (r"\b_combat_status\b", "combat_status"),
    (r"\bPRIORITY_TICK\b", "_event_priority"),
    # one-line WorldState delegations -> the ObjectTable methods they delegated to
    (r"(?<![\w.])get_object_faction_id,", "_object_table.get_object_faction_id,"),
    (r"(?<![\w.])get_object,", "_object_table.get_object,"),
    # injected Callables
    (r"(?<![\w.])(_remove_colonist_by_id|_job_restricted_to|_finish_job|_resolve_giver_association)\(",
     r"\1.call("),
    (r"(?<![\w.])is_tool_kind\(", "_is_tool_kind.call("),
    (r"(?<![\w.])spawn_ground_tool_item\(", "_spawn_ground_tool_item.call("),
    (r"_approach_giver\.forget\(", "_approach_forget.call("),
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


def rename(text, new):
    for old, n in MOVED:
        if old != n:
            text = re.sub(r"(?<![\w.])" + re.escape(old) + r"\(", n + "(", text)
    for pattern, repl in (STATIC_RENAMES if new in SIGNATURES else RENAMES):
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
            print(rename("\n".join(body(old_lines, old)), new) + "\n")
        return
    new_lines = open(NEW_PATH, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    cur_lines = open(OLD_PATH, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    bad = 0
    for old, new in MOVED:
        old_body = body(old_lines, old)
        expected = code_only(rename("\n".join(old_body), new).split("\n"))
        got = body(new_lines, new)
        got_code = code_only(got) if got is not None else None
        ok = got_code is not None and got_code[1:] == expected[1:]
        if ok and new in SIGNATURES:
            ok = got_code[0] == SIGNATURES[new]
        elif ok:
            ok = got_code[0] == expected[0]
        bad += not ok
        still_there = body(cur_lines, old) is not None
        print("%-28s -> %-28s %s%s" % (old, new, "OK" if ok else "DIFFERS",
                                        "  (WorldState keeps a delegation)" if still_there else ""))
    print("move_check: %d function(s), %d differ" % (len(MOVED), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

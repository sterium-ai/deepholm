"""R10: checks that every function moved out of WorldState by R10 is a move.

For each moved function it takes the body from the base ref's world_state.gd, applies
the mechanical renames listed for it (new names, injected Callables, handler
receivers), and compares it, statement by statement with comment lines, blank lines
and the `func` line dropped, with the body in its new file. Signatures are printed for
the reader (the new ones take `command` where the old place_object/cancel_site checks
took `payload`, and the CommandChecks ones are static with a `world` parameter).

ADDED lists the only statements a new body has that the old one did not.

Usage (repo root):
    python docs/orca/handoffs/R10-move_check.py [base-ref]      # default base: main
"""
import re
import subprocess
import sys

WS = "game/scripts/core/world_state.gd"
ROUTER = "game/scripts/core/world/command_router.gd"
CHECKS = "game/scripts/core/commands/command_checks.gd"
H = "game/scripts/core/commands/handlers/"

# A CommandChecks rule called with the world -> the same rule through the injected Callable.
CHECK_CALL = (r"var check := CommandChecks\.(\w+)\(self, command\)",
              r"var check: Dictionary = _check.call(CommandChecks.\1, command)")

# (old name in WorldState, new file, new name, renames applied in order)
MOVED = [
    ("preview", ROUTER, "preview", [
        (r"(?<![\w.])_validate_command\(", "validate_command("),
        (r"(?<![\w.])_construction\.", "_construction_system."),
        (r"(?<![\w.])_check_(cancel_site|place_object)_command\(command\[\"payload\"\]\)",
         r"_check.call(CommandChecks.check_\1_command, command)"),
        (r"CommandChecks\.check\(self, command\)", "_check.call(CommandChecks.check, command)"),
    ]),
    ("apply", ROUTER, "apply", [
        (r"(?<![\w.])_validate_command\(", "validate_command("),
        (r"(?<![\w.])_apply_(job|cancel_job)_command\(", r"_orders.apply_\1_command("),
        (r"_construction\.apply_construction_submission\(", "_construction.apply_build_command("),
        (r"_area_orders\.apply_command\(command, get_map_width\(\), get_map_height\(\)\)",
         "_orders.apply_area_order_command(command)"),
        (r"(?<![\w.])_apply_(cancel_site|place_object|remove_object)_command\(", r"_construction.apply_\1_command("),
        (r"(?<![\w.])_apply_(set_labour|set_faction)_command\(", r"_actors.apply_\1_command("),
        (r"(?<![\w.])_apply_(spawn_incident)_command\(", r"_incidents.apply_\1_command("),
        (r"_trade\.apply_accept_trade_command\(", "_incidents.apply_accept_trade_command("),
        (r"(?<![\w.])_apply_(zone_add|zone_remove)_command\(", r"_zones.apply_\1_command("),
    ]),
    ("_validate_command", ROUTER, "validate_command", []),
    ("_apply_job_command", H + "order_handler.gd", "apply_job_command", [
        CHECK_CALL,
        (r"(?<![\w.])(_drop_carried_haul_item|_finish_job|_resolve_giver_association|_resolve_refused_reservations)\(",
         r"\1.call("),
    ]),
    ("_apply_cancel_job_command", H + "order_handler.gd", "apply_cancel_job_command", [
        (r"(?<![\w.])_apply_job_command\(", "apply_job_command("),
    ]),
    ("_apply_cancel_site_command", H + "construction_handler.gd", "apply_cancel_site_command", [
        (r"var check := _check_cancel_site_command\(payload\)",
         "var check: Dictionary = _check.call(CommandChecks.check_cancel_site_command, command)"),
    ]),
    ("_apply_place_object_command", H + "construction_handler.gd", "apply_place_object_command", [
        (r"var check := _check_place_object_command\(payload\)",
         "var check: Dictionary = _check.call(CommandChecks.check_place_object_command, command)"),
    ]),
    ("_apply_remove_object_command", H + "construction_handler.gd", "apply_remove_object_command", [CHECK_CALL]),
    ("_apply_set_labour_command", H + "actor_handler.gd", "apply_set_labour_command", [
        CHECK_CALL, (r"var (\w+) := _find_colonist\(", r"var \1: Dictionary = _find_colonist.call("),
    ]),
    ("_apply_set_faction_command", H + "actor_handler.gd", "apply_set_faction_command", [
        CHECK_CALL, (r"var (\w+) := _find_colonist\(", r"var \1: Dictionary = _find_colonist.call("),
    ]),
    ("_apply_spawn_incident_command", H + "incident_handler.gd", "apply_spawn_incident_command", [
        CHECK_CALL, (r"_incidents\.force_spawn\(", "_force_spawn.call("),
    ]),
    ("_apply_zone_add_command", H + "zone_handler.gd", "apply_zone_add_command", [CHECK_CALL]),
    ("_apply_zone_remove_command", H + "zone_handler.gd", "apply_zone_remove_command", [CHECK_CALL]),
    ("_fail_haul_jobs_targeting_removed_zone", H + "zone_handler.gd", "_fail_haul_jobs_targeting_removed_zone", [
        (r"(?<![\w.])_terminate_haul_job_by_id\(", "_terminate_haul_job_by_id.call("),
    ]),
    ("_check_place_object_command", CHECKS, "check_place_object_command", [
        (r"(?<![\w.])(_object_definitions|_object_table|_tile_grid)\b", r"world.\1"),
        (r"(?<![\w.])(_colonist_at|get_object|get_tile)\(", r"world.\1("),
        (r"(?<![\w.])(TILE_TREE|TILE_WATER)\b", r"WorldState.\1"),
    ]),
    ("_check_cancel_site_command", CHECKS, "check_cancel_site_command", [
        (r"(?<![\w.])_construction\.", "world._construction."),
    ]),
]

PAYLOAD_LINE = '\tvar payload: Dictionary = command["payload"]'
ADDED = {
    "check_place_object_command": [PAYLOAD_LINE],
    "check_cancel_site_command": [PAYLOAD_LINE],
}


def git_show(ref, path):
    return subprocess.run(["git", "show", "%s:%s" % (ref, path)], capture_output=True,
                          check=True).stdout.decode("utf-8").replace("\r\n", "\n")


def read(path):
    return open(path, encoding="utf-8").read().replace("\r\n", "\n").split("\n")


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


def code_only(lines):
    return [l.rstrip() for l in lines if l.strip() and not l.strip().startswith("#")]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    base = args[0] if args else "main"
    old_lines = git_show(base, WS).split("\n")
    cur_ws = read(WS)
    bad = 0
    for old, path, new, renames in MOVED:
        old_body = body(old_lines, old)
        text = "\n".join(old_body[1:])
        for pattern, repl in renames:
            text = re.sub(pattern, repl, text)
        expected = code_only(text.split("\n"))
        got = body(read(path), new)
        got_code = code_only(got[1:]) if got is not None else None
        if got_code is not None:
            for added in ADDED.get(new, []):
                if added in got_code:
                    got_code.remove(added)
        ok = got_code == expected
        bad += not ok
        # preview/apply stay in WorldState as one-line delegations; everything else must be gone.
        still_there = old not in ("preview", "apply") and body(cur_ws, old) is not None
        print("%-40s -> %-60s %s%s" % (old, path.split("core/")[1] + ":" + new, "OK" if ok else "DIFFERS",
                                        "  (old name still defined in WorldState)" if still_there else ""))
        if not ok and "--verbose" in sys.argv:
            print("  expected:\n    " + "\n    ".join(expected) + "\n  got:\n    " + "\n    ".join(got_code or []))
        print("    old: %s\n    new: %s" % (old_body[0], got[0] if got else "-"))
    print("move_check: %d function(s), %d differ" % (len(MOVED), bad + 0))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

"""R7: checks that every function moved from WorldState into TradeSystem is a move.

For each moved function it takes the body from the base ref's world_state.gd, applies the
mechanical renames below (new names, injected Callables, the renamed field), and
compares it, statement by statement with comment lines and blank lines dropped, with
the body now in economy/trade_system.gd. `--emit` prints the renamed bodies instead.

Usage (repo root):
    python docs/orca/handoffs/R7-move_check.py [base-ref]          # default base: main
    python docs/orca/handoffs/R7-move_check.py --emit [base-ref]
"""
import re
import subprocess
import sys

OLD_PATH = "game/scripts/core/world_state.gd"
NEW_PATH = "game/scripts/core/economy/trade_system.gd"

# old name in WorldState -> name in TradeSystem (public ones lose the "_").
# get_pending_trade_offers keeps a one-line delegation in WorldState (public surface).
MOVED = [
    ("_maybe_post_trade_offer", "maybe_post_trade_offer"),
    ("_post_trade_offer", "_post_trade_offer"),
    ("_pick_trade_items", "_pick_trade_items"),
    ("_apply_accept_trade_command", "apply_accept_trade_command"),
    ("_append_trader_inventory_item", "_append_trader_inventory_item"),
    ("_remove_trader_offered_item", "_remove_trader_offered_item"),
    ("get_pending_trade_offers", "get_pending_trade_offers"),
]

# Applied in order to every old body after the function-name renames.
RENAMES = [
    (r"\b_pending_trade_offers\b", "pending_offers"),
    (r"var actor := _find_job_colonist\(", "var actor: Dictionary = _find_job_colonist.call("),
    (r"var trader := _find_colonist\(", "var trader: Dictionary = _find_colonist.call("),
    (r"(?<![\w.])is_tool_kind\(", "_is_tool_kind.call("),
    (r"\b_finish_job\(", "_finish_job.call("),
    (r"\b_remove_colonist_by_id\(", "_remove_colonist_by_id.call("),
    (r"\bPRIORITY_TICK\b", "_priority_tick"),
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
        print("%-32s -> %-32s %s%s" % (old, new, "OK" if ok else "DIFFERS",
                                        "  (delegation kept in WorldState)" if still_there else ""))
    print("move_check: %d function(s), %d differ" % (len(MOVED), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

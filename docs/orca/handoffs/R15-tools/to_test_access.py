"""R15: rewrite `<x>world._member` accesses in GDScript test files into TestAccess calls.
Usage: python to_test_access.py <file.gd>...   (rewrites in place, prints per-file counts)"""
import re
import sys

import os
RECV = os.environ.get("R15_RECV", r"((?:[A-Za-z_]\w*\.)*[A-Za-z_]*world)")
MEMBER_FILTER = set(filter(None, os.environ.get("R15_MEMBERS", "").split("|")))
METHODS = {"find_colonist", "get_job", "job_restricted_to", "append_colonist", "resolve_refused_reservations",
           "flee_target_reserved", "colonist_at", "remove_colonist_by_id", "default_labour_table", "cell_key",
           "tile_key", "submit_incident_job", "set_work_progress", "resubmit_unreachable_job", "is_cell_occupied"}
SETTABLE = {"colonists", "calendar"}
# second-level private chains: chain -> (TestAccess name, kind) kind: read | method | settable
CHAINS = {
    "_scheduler.queue._jobs": ("queue_jobs", "read"),
    "_scheduler.queue._events": ("queue_events", "read"),
    "_scheduler.queue._haul_retry_base_ticks": ("queue_haul_retry_base_ticks", "read"),
    "_scheduler.queue._haul_retry_cap_ticks": ("queue_haul_retry_cap_ticks", "read"),
    "_scheduler._find_waiting_entry": ("scheduler_find_waiting_entry", "method"),
    "_item_table._ids_at_trusted": ("item_ids_at_trusted", "read"),
    "_tick_pipeline._colonists_not_searching_need": ("colonists_not_searching_need", "method"),
    "_need_giver._pending": ("need_giver_pending", "read"),
    "_need_giver._searching": ("need_giver_searching", "read"),
    "_rescue_giver._searching": ("rescue_giver_searching", "read"),
    "_rescue_giver._job_victim": ("rescue_giver_job_victim", "read"),
    "_combat_giver._episodes": ("combat_giver_episodes", "read"),
    "_combat_giver._fleeing": ("combat_giver_fleeing", "read"),
    "_incidents._random": ("incident_random", "read"),
    "_incidents._last_processed_day": ("incident_last_processed_day", "settable"),
    "_incidents._cooldown_until_day": ("incident_cooldown_until_day", "settable"),
    "_incidents._staged": ("incident_staged", "read"),
    "_incidents._actor_by_job": ("incident_actor_by_job", "read"),
    "_incidents._spawn": ("incident_spawn", "method"),
    "_event_log._events": ("event_log_events", "read"),
    "_event_log._event_sequence": ("event_log_sequence", "read"),
}
OPEN, CLOSE = "([{", ")]}"


def balanced_end(text, i):
    """End index of the expression starting at i: stops at depth-0 newline/comment or an unbalanced closer."""
    depth, quote = 0, None
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c in OPEN:
            depth += 1
        elif c in CLOSE:
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (c in "\r\n" or c == "#"):
            break
        i += 1
    while i > 0 and text[i - 1] in " \t":
        i -= 1
    return i


def close_paren(text, i):
    """Index of the ')' matching the '(' at i-1."""
    depth, quote = 1, None
    while True:
        c = text[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c in OPEN:
            depth += 1
        elif c in CLOSE:
            depth -= 1
            if depth == 0:
                return i
        i += 1


ASSIGN = re.compile(r"[ \t]*=(?!=)[ \t]*")
TILE = re.compile(RECV + r"\._tile_grid\.tiles\[(\1)\._tile_grid\.tile_index\(")
ANY = re.compile(RECV + r"\._([a-z_]+)((?:\.[a-z_]+)*?)(?=[^\w]|$)")


def convert(text):
    count = 0
    while True:
        m = TILE.search(text)
        if not m:
            break
        recv = m.group(1)
        args_end = close_paren(text, m.end())
        args = text[m.end():args_end]
        after = args_end + 2  # ")]"
        assert text[args_end:after] == ")]", text[m.start():after + 20]
        a = ASSIGN.match(text, after)
        if a:
            rhs_end = balanced_end(text, a.end())
            text = text[:m.start()] + "TestAccess.set_tile(%s, %s, %s)" % (recv, args, text[a.end():rhs_end]) + text[rhs_end:]
        else:
            text = text[:m.start()] + "TestAccess.tile_at(%s, %s)" % (recv, args) + text[after:]
        count += 1
    pos = 0
    while True:
        m = re.compile(RECV + (r"\.(?=(?:%s)\b)" % "|".join(sorted(MEMBER_FILTER)) if MEMBER_FILTER else r"\._")).search(text, pos)
        if m and MEMBER_FILTER:
            m = re.compile(RECV + r"\._").match(text, m.start())
        if not m:
            break
        recv, start = m.group(1), m.start()
        rest = text[m.end() - 1:]
        name, kind, consumed = None, None, 0
        for chain in sorted(CHAINS, key=len, reverse=True):
            if rest.startswith(chain) and not re.match(r"\w", rest[len(chain):len(chain) + 1]):
                name, kind = CHAINS[chain]
                consumed = len(chain)
                break
        if name is None:
            member = re.match(r"_([a-z_]+)", rest).group(1)
            consumed = len(member) + 1
            name = member
            kind = "method" if member in METHODS else ("settable" if member in SETTABLE else "read")
        end = m.end() - 1 + consumed
        if kind == "method":
            assert text[end] == "(", text[start:end + 30]
            sep = "" if text[end + 1] == ")" else ", "
            repl = "TestAccess.%s(%s%s" % (name, recv, sep)
            text = text[:start] + repl + text[end + 1:]
        else:
            a = ASSIGN.match(text, end)
            if kind == "settable" and a:
                rhs_end = balanced_end(text, a.end())
                repl = "TestAccess.set_%s(%s, %s)" % (name, recv, text[a.end():rhs_end])
                text = text[:start] + repl + text[rhs_end:]
            else:
                assert not a, "unexpected assignment: " + text[start:end + 40]
                repl = "TestAccess.%s(%s)" % (name, recv)
                text = text[:start] + repl + text[end:]
        pos = start + len("TestAccess.")
        count += 1
    return text, count


if __name__ == "__main__":
    total = 0
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8", newline="") as f:
            src = f.read()
        out, n = convert(src)
        if n:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(out)
            print("%5d  %s" % (n, path))
        total += n
    print("total", total)

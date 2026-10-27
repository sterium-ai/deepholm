"""A1 evidence: does a tools/run_benches.ps1 run reproduce the A0 benchmark lines?

Compares docs/orca/handoffs/A0-bench-results.txt with a raw-lines file from
`tools\\run_benches.ps1 -RawOut <file>` (or the raw lines of bench-baseline.md).
Each line's shape (its text with every number replaced by #) must match, in
order. Every value that is not a timing must be equal; timings (ms, us, wall
seconds, phase splits) are not compared. On a line that ends in a phase list
(top_phases:, phases[...]) the values before the list are still compared.
Numbers outside key=value pairs ("12999 bytes", "+100 items", "(225, 31)") are
compared too, unless they are timings ("22.7ms", "177.9 us per added entry").

Lines are matched by shape, in order within a shape (both runs print idle,
then busy, then needs; A0's needs lines come from its separate re-run).

Usage: python -I docs/orca/handoffs/A1-compare-a0.py <new-raw-lines.txt>
Exit 0 when every non-timing value matches.
"""
import re
import sys
from pathlib import Path

A0 = Path(__file__).with_name("A0-bench-results.txt")
NUM = re.compile(r"-?\d+(?:\.\d+)?")
# Tokens whose value is wall-clock (host-dependent). Everything else must match.
TIMING_KEY = re.compile(r"(ms|us|mean|p50|p95|max|first|time|setup|load|wall|mean_tick|_state|stringify|"
                        r"encode|decode|write_atomic|read\+integrity|total_save|total_load|us/expansion)$")
PHASES = re.compile(r"(phases\[|top_phases:|JSON\.parse_string)")
# The per-phase splits themselves: everything from here on is timings.
PHASE_LIST = re.compile(r"(phases\[|top_phases:)")
SKIP = re.compile(r": commit=|: done$|: wall=")
# Values that may differ for a known reason, reported as "expected" rather than as mismatches:
# - bench_tick_scaling stops a run after RUN_BUDGET_USEC of measured ticks, so on a faster or
#   slower host `n` differs, and so does the state after n ticks (jobs/active/events).
# - the leak check's Object counts depend on the code: A0 ran on 052d8c4, and R4-R7 since then
#   added core modules (more Objects per WorldState).
BUDGET_STATE = {"jobs", "active", "events"}
CODE_DEPENDENT = {"before", "WorldStates", "(delta"}


def lines(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8-sig")
    return [l.strip() for l in text.splitlines() if l.startswith("bench_")]


def key(line: str) -> str:
    """A line's shape: every number masked, phase lists (which vary) cut off."""
    line = PHASES.split(line)[0]
    return NUM.sub("#", line)


PAIR = re.compile(r"([\w/+()\[\].]+)=([^\s,)]+)")
# A bare number that is a timing: "22.7ms", "177.9 us per added entry".
BARE_TIMING = re.compile(r"\s*(ms|us)\b")


def pairs(line: str) -> list[tuple[str, str]]:
    return PAIR.findall(line)


def bare_numbers(line: str) -> list[str]:
    """The numbers outside key=value pairs that are not timings, e.g. "12999 bytes", "+100 items"."""
    rest = PAIR.sub(" ", line)
    return [m.group(0) for m in NUM.finditer(rest) if not BARE_TIMING.match(rest, m.end())]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    old = [l for l in lines(A0) if not SKIP.search(l)]
    new = [l for l in lines(Path(sys.argv[1])) if not SKIP.search(l)]
    new_by_key: dict[str, list[str]] = {}
    for l in new:
        new_by_key.setdefault(key(l), []).append(l)
    mismatches = 0
    matched = 0
    for l in old:
        k = key(l)
        if not new_by_key.get(k):
            # Shape differs: show both so a human can see which value moved.
            print("NO MATCH  A0 : " + l)
            mismatches += 1
            continue
        n = new_by_key[k].pop(0)
        matched += 1
        # Phase splits are timings throughout; the counts before them (ticks, queue sizes,
        # open_orders, n, ...) are not.
        old_pairs, new_pairs = pairs(PHASE_LIST.split(l)[0]), pairs(PHASE_LIST.split(n)[0])
        # Only bench_tick_scaling has a run budget; every other n (e.g. the backlog's 50) is fixed.
        budgeted = l.startswith("bench_tick_scaling:")
        n_changed = budgeted and dict(old_pairs).get("n") != dict(new_pairs).get("n")
        for (ka, va), (kb, vb) in zip(old_pairs, new_pairs):
            if ka != kb or TIMING_KEY.search(ka) or va == vb:
                continue
            if (budgeted and ka == "n") or (n_changed and ka in BUDGET_STATE):
                reason = "run budget: a different number of ticks fit in RUN_BUDGET_USEC"
            elif ka in CODE_DEPENDENT:
                reason = "Object count depends on the code (R4-R7 landed after A0)"
            else:
                reason = ""
            print(f"{'expected' if reason else 'DIFF'} {ka}: A0={va} now={vb}"
                  f"{'  (' + reason + ')' if reason else ''}\n  A0 : {l}\n  now: {n}")
            if not reason:
                mismatches += 1
        old_bare, new_bare = bare_numbers(PHASE_LIST.split(l)[0]), bare_numbers(PHASE_LIST.split(n)[0])
        if old_bare != new_bare:
            print(f"DIFF bare numbers: A0={old_bare} now={new_bare}\n  A0 : {l}\n  now: {n}")
            mismatches += 1
    leftover = [l for v in new_by_key.values() for l in v]
    print(f"compare-a0: {matched} of {len(old)} A0 lines matched by shape, {mismatches} mismatch(es), "
          f"{len(leftover)} new line(s) without an A0 counterpart")
    for l in leftover:
        print("  new only: " + l)
    return 0 if mismatches == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

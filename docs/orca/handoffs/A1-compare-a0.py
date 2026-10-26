"""A1 evidence: does a tools/run_benches.ps1 run reproduce the A0 benchmark lines?

Compares docs/orca/handoffs/A0-bench-results.txt with a raw-lines file from
`tools\\run_benches.ps1 -RawOut <file>` (or the raw lines of bench-baseline.md).
Each line's shape (its text with every number replaced by #) must match, in
order. Every value that is not a timing must be equal; timings (ms, us, wall
seconds, phase splits) are only listed side by side.

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
SKIP = re.compile(r": commit=|: done$|: wall=")
# Values that may differ for a known reason, reported as "expected" rather than as mismatches:
# - bench_tick_scaling stops a run after RUN_BUDGET_USEC of measured ticks, so on a faster or
#   slower host `n` differs, and so does the state after n ticks (jobs/active/events).
# - the leak check's Object counts depend on the code: A0 ran on 052d8c4, and R4-R6 since then
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


def pairs(line: str) -> list[tuple[str, str]]:
    return re.findall(r"([\w/+()\[\].]+)=([^\s,)]+)", line)


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
        if PHASES.search(l):
            continue  # phase splits are timings throughout
        old_pairs, new_pairs = pairs(l), pairs(n)
        n_changed = dict(old_pairs).get("n") != dict(new_pairs).get("n")
        for (ka, va), (kb, vb) in zip(old_pairs, new_pairs):
            if ka != kb or TIMING_KEY.search(ka) or va == vb:
                continue
            if ka == "n" or (n_changed and ka in BUDGET_STATE):
                reason = "run budget: a different number of ticks fit in RUN_BUDGET_USEC"
            elif ka in CODE_DEPENDENT:
                reason = "Object count depends on the code (R4-R6 landed after A0)"
            else:
                reason = ""
            print(f"{'expected' if reason else 'DIFF'} {ka}: A0={va} now={vb}"
                  f"{'  (' + reason + ')' if reason else ''}\n  A0 : {l}\n  now: {n}")
            if not reason:
                mismatches += 1
    leftover = [l for v in new_by_key.values() for l in v]
    print(f"compare-a0: {matched} of {len(old)} A0 lines matched by shape, {mismatches} mismatch(es), "
          f"{len(leftover)} new line(s) without an A0 counterpart")
    for l in leftover:
        print("  new only: " + l)
    return 0 if mismatches == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

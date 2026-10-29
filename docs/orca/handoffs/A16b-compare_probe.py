"""A16b evidence: compares two output dirs of docs/orca/handoffs/A16-scenario_dump.gd (main and
the branch) line by line. hash@N and events@0 lines must be identical; save@N lines must be
identical once the branch save's schemaVersion (4 on the branch, 3 on main) and its added
scenarioStart are set aside, and that scenarioStart must be the base start.
Usage: python A16b-compare_probe.py <main out dir> <branch out dir>
"""
import json
import os
import sys

BASE_START = {"calendar": None, "enabledIncidents": []}


def main(main_dir: str, branch_dir: str) -> int:
    failures = 0
    for name in sorted(os.listdir(main_dir)):
        with open(os.path.join(main_dir, name), encoding="utf-8") as f:
            before = f.read().split("\n")
        with open(os.path.join(branch_dir, name), encoding="utf-8") as f:
            after = f.read().split("\n")
        problems = []
        if len(before) != len(after):
            problems.append("line count %d != %d" % (len(before), len(after)))
        for old, new in zip(before, after):
            if old.startswith("save@"):
                tag, old_json = old.split(" ", 1)
                new_tag, new_json = new.split(" ", 1)
                old_state, new_state = json.loads(old_json), json.loads(new_json)
                start = new_state.pop("scenarioStart", "missing")
                if start != BASE_START:
                    problems.append("%s scenarioStart is %s" % (tag, start))
                if old_state.pop("schemaVersion") != 3 or new_state.pop("schemaVersion") != 4:
                    problems.append("%s schemaVersion is not 3 -> 4" % tag)
                if tag != new_tag or old_state != new_state:
                    problems.append("%s differs" % tag)
            elif old != new:
                problems.append("%s differs" % old.split(" ", 1)[0])
        status = "identical (save: schemaVersion 3 -> 4, base-start scenarioStart added)" if not problems else "; ".join(problems)
        print("%s: %s" % (name, status))
        failures += 1 if problems else 0
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))

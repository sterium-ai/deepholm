"""R9: retargets tests from WorldState's moved private members to their new owner.

Receiver renames only (`world._apply_actor_death(` -> `world._combat_system.apply_actor_death(`): every
rewrite is a call `world.` + old name + `(` -> `world.` + new owner path + `(` (comments
that name the old function are left alone), so `--check` can undo the
mapping on each changed file and compare it byte-for-byte with `main`.

Usage (repo root):
    python docs/orca/handoffs/R9-retarget_tests.py          # apply
    python docs/orca/handoffs/R9-retarget_tests.py --check [base-ref]  # verify against main
"""
import glob
import re
import subprocess
import sys

# (old member after "world.", new member path after "world."). Order matters only for --check's inverse.
MAP = [
    ("_apply_actor_death", "_combat_system.apply_actor_death"),
    ("_apply_combat", "_combat_system.apply_combat"),
]
TESTS = "game/scripts/tests"
BASE = next((a for a in sys.argv[1:] if not a.startswith("--")), "main")


def forward(text):
    for old, new in MAP:
        text = re.sub(r"\bworld\." + re.escape(old) + r"\(", "world." + new + "(", text)
    return text


def inverse(text):
    for old, new in MAP:
        text = re.sub(r"\bworld\." + re.escape(new) + r"\(", "world." + old + "(", text)
    return text


def main():
    if "--check" in sys.argv:
        changed = subprocess.run(["git", "diff", "--name-only", BASE, "--", TESTS],
                                 capture_output=True, text=True, check=True).stdout.split()
        bad = 0
        for path in changed:
            cur = open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")
            base = subprocess.run(["git", "show", BASE + ":" + path], capture_output=True, check=True).stdout
            base = base.decode("utf-8").replace("\r\n", "\n")
            ok = inverse(cur) == base
            bad += not ok
            print(path, "OK" if ok else "DIFFERS")
        print("retarget_check: %d file(s), %d differ" % (len(changed), bad))
        sys.exit(1 if bad else 0)
    count = 0
    for path in sorted(glob.glob(TESTS + "/test_*.gd") + glob.glob(TESTS + "/bench_*.gd")):
        raw = open(path, encoding="utf-8", newline="").read()
        new = forward(raw)
        if new != raw:
            open(path, "w", encoding="utf-8", newline="").write(new)
            count += 1
    print("retargeted %d file(s)" % count)


if __name__ == "__main__":
    main()

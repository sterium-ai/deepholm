"""R8: retargets tests from WorldState's moved private members to their new owner.

Receiver renames only (`world._paused_jobs` -> `world._needs_system.paused_jobs`): every
rewrite is a `.` + old name -> `.` + new owner path, so `--check` can undo the
mapping on each changed file and compare it byte-for-byte with `main`.

Usage (repo root):
    python docs/orca/handoffs/R8-retarget_tests.py          # apply
    python docs/orca/handoffs/R8-retarget_tests.py --check  # verify against main
"""
import glob
import re
import subprocess
import sys

# (old member after ".", new member path after "."). Order matters only for --check's inverse.
MAP = [
    ("_paused_jobs", "_needs_system.paused_jobs"),
    ("_need_status", "_needs_system.need_status"),
    ("_interrupt_current_job", "_needs_system.interrupt_current_job"),
    ("_resume_interrupted_job", "_needs_system.resume_interrupted_job"),
    ("_pause_work_job", "_needs_system.pause_work_job"),
    ("_resume_paused_job", "_needs_system.resume_paused_job"),
    ("_decay_needs", "_needs_system.decay_needs"),
    ("_need_source_candidates", "_needs_system.need_source_candidates"),
]
TESTS = "game/scripts/tests"


def forward(text):
    for old, new in MAP:
        text = re.sub(r"\." + re.escape(old) + r"\b", "." + new, text)
    return text


def inverse(text):
    for old, new in MAP:
        text = re.sub(r"\." + re.escape(new) + r"\b", "." + old, text)
    return text


def main():
    if "--check" in sys.argv:
        changed = subprocess.run(["git", "diff", "--name-only", "main", "--", TESTS],
                                 capture_output=True, text=True, check=True).stdout.split()
        bad = 0
        for path in changed:
            cur = open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")
            base = subprocess.run(["git", "show", "main:" + path], capture_output=True, check=True).stdout
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

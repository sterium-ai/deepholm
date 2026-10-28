"""R15 evidence: rebuild the branch's game/scripts/tests from <base-rev> with the mechanical
scripts in this folder, then compare with the working tree.

Inputs taken from the branch (hand-written, reviewed as diff): core/world/test_access.gd,
tests/support/scenarios.gd and the rule-4 block of tests/test_architecture_rules.gd.
Everything else under tests/ must come out of the pipeline byte-identical (line endings
ignored). It also checks the split: every function of each pre-split file appears once, with
identical text, in support/<subject>_base.gd plus the test_<subject>*.gd files, and the _init
check lists are the same set.

Run from the repo root:  python docs/orca/handoffs/R15-tools/reproduce.py [base-rev]
(default origin/main). Exit 0 = identical."""
import glob
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
RECEIVERS = ("loaded|restored|live|uninterrupted|reenable_while_searching|only_enabled_searching|"
             "all_searching|world_b|w|pocket|world_door|world_a|unknown_assignee|enclosed|source|"
             "impassable|b|world_below|world_at|with_incidents|twin|restored_after|refused_assignee|"
             "reference|missing_seed|straight|restored_wait|reloaded|probe|outside|occupied|inside|"
             "from_record|a")
# Private statics and members reached without a WorldState receiver: (regex, replacement).
STATICS = [
    (r"\bSaveIOType\._validate_state\(", "TestAccess.save_validate_state("),
    (r"\bSaveIOType\._sha256\(", "TestAccess.save_sha256("),
    (r"\bWorldGeneratorType\._scatter_rock_outcrops\(", "TestAccess.generator_scatter_rock_outcrops("),
    (r"\bWorldGeneratorType\._count_reachable_food_sources\(", "TestAccess.generator_count_reachable_food_sources("),
    (r"\bscheduler\._pending\b", "TestAccess.assignment_pending(scheduler)"),
    (r"\bqueue\._emit\(", "TestAccess.queue_emit(queue, "),
    (r"TestAccess\.need_giver\(loaded\)\._bounds_max", "TestAccess.need_giver_bounds_max(loaded)"),
    (r"TestAccess\.incidents\(loaded\)\._map_width", "TestAccess.incident_map_width(loaded)"),
    (r"TestAccess\.incidents\(loaded\)\._map_height", "TestAccess.incident_map_height(loaded)"),
    (r"TestAccess\.scheduler\(world\)\.queue\._history\.size\(\)", "TestAccess.queue_history(world).size()"),
    (r"\bqueue\._jobs\.size\(\)", "TestAccess.queue_live_jobs(queue).size()"),
    (r"\bSchedulingCodecType\._encode_jobs\(", "TestAccess.scheduling_encode_jobs("),
    (r'const SchedulingCodecType = preload\("res://scripts/core/persistence/scheduling_codec\.gd"\)\r?\n', ""),
]


def run(args, env=None):
    subprocess.run([sys.executable] + args, check=True, env=env, stdout=subprocess.DEVNULL)


def read(path):
    return open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")


def funcs(text):
    out = {}
    for m in re.finditer(r"^func (\w+)\(.*?(?=^\S(?<!\t)|\Z)", text, re.M | re.S):
        if m.group(1) != "_init":
            out.setdefault(m.group(1), []).append(m.group(0).rstrip())
    return out


def main():
    tmp = tempfile.mkdtemp(prefix="r15_")
    try:
        data = subprocess.run(["git", "archive", BASE, "game/scripts"], capture_output=True, check=True).stdout
        tarfile.open(fileobj=io.BytesIO(data)).extractall(tmp, filter="data")
        tests = os.path.join(tmp, "game", "scripts", "tests")
        os.makedirs(os.path.join(tests, "support"), exist_ok=True)
        shutil.copy("game/scripts/tests/support/scenarios.gd", os.path.join(tests, "support"))
        files = sorted(glob.glob(os.path.join(tests, "*.gd")))
        # 1. world._x -> TestAccess.x(world), then other WorldState receivers.
        run([os.path.join(HERE, "to_test_access.py")] + files)
        world_state = read(os.path.join(tmp, "game", "scripts", "core", "world_state.gd"))
        members = sorted(set(re.findall(r"^(?:var|func) (_[a-z_]+)", world_state, re.M)))
        env = dict(os.environ, R15_RECV=r"\b(%s)" % RECEIVERS, R15_MEMBERS="|".join(members))
        run([os.path.join(HERE, "to_test_access.py")] + files, env=env)
        # 2. private statics / members of modules used without a world.
        for path in files:
            raw = open(path, encoding="utf-8", newline="").read()
            new = raw
            for pattern, repl in STATICS:
                new = re.sub(pattern, repl, new)
            if new != raw:
                open(path, "w", encoding="utf-8", newline="").write(new)
        # 3. rule 4 (hand-written) comes from the branch; 4. dedupe; 5. split.
        shutil.copy("game/scripts/tests/test_architecture_rules.gd", tests)
        run([os.path.join(HERE, "dedupe_scenarios.py"), tests])
        pre_split = {s: read(os.path.join(tests, "test_%s.gd" % s)) for s in ["tool_items", "combat", "rescue"]}
        for subject in pre_split:
            run([os.path.join(HERE, "split_test.py"), tests, "test_" + subject,
                 os.path.join(HERE, "rules_%s.json" % subject)])
        ok = True
        # Split integrity against the pre-split text.
        for subject, original in pre_split.items():
            paths = ["game/scripts/tests/support/%s_base.gd" % subject, "game/scripts/tests/test_%s.gd" % subject]
            paths += sorted(glob.glob("game/scripts/tests/test_%s_*.gd" % subject))
            after = {}
            calls = []
            for p in paths:
                text = read(p)
                for name, bodies in funcs(text).items():
                    after.setdefault(name, []).extend(bodies)
                if p != paths[0]:
                    calls += re.findall(r"^\t(_check_\w+)\(\)$", text, re.M)
            before = funcs(original)
            bad = [k for k in before if before[k] != after.get(k)] + [k for k in after if k not in before]
            same = sorted(calls) == sorted(re.findall(r"^\t(_check_\w+)\(\)$", original, re.M))
            ok = ok and not bad and same
            print("split %-10s %3d functions, mismatches: %s, _init check set %s" % (
                subject, len(before), bad or "none", "same" if same else "DIFFERENT"))
        # Whole-tree comparison.
        rebuilt = {os.path.relpath(p, tests).replace("\\", "/") for p in glob.glob(os.path.join(tests, "**", "*.gd"), recursive=True)}
        branch = {os.path.relpath(p, "game/scripts/tests").replace("\\", "/") for p in glob.glob("game/scripts/tests/**/*.gd", recursive=True)}
        differ = sorted(f for f in rebuilt & branch if read(os.path.join(tests, f)) != read(os.path.join("game/scripts/tests", f)))
        only = sorted(rebuilt ^ branch)
        ok = ok and not differ and not only
        print("tests/*.gd rebuilt from %s: %d files, differing: %s, only on one side: %s" % (
            BASE, len(rebuilt), differ or "none", only or "none"))
        return 0 if ok else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


sys.exit(main())

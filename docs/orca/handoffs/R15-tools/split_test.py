"""R15: split one large headless test file by subject without changing any function.
The original file's header, members and every helper go to tests/support/<name>_base.gd
(extends SceneTree); each entry check (a `_check_*()` call in _init that nothing else calls)
moves, with its doc comment, to the subject file chosen by `rules`; each subject file
extends the base and runs its checks in their original order.
Usage: python split_test.py <tests dir> <name> <rules.json>
rules.json: [["<subject suffix or ''>", "<regex on the check name>"], ...] first match wins;
'' keeps the original file name. A check matching no rule is an error."""
import json
import os
import re
import sys


def blocks(lines):
    """Split into ("func", name, lines) and ("other", None, lines) blocks; a func block owns
    the ## / # comment lines right above it and the blank lines after it."""
    out, i, pending = [], 0, []
    while i < len(lines):
        line = lines[i]
        m = re.match(r"func (\w+)\(", line)
        if m:
            j = i + 1
            while j < len(lines) and (lines[j].startswith("\t") or lines[j].strip() == ""):
                j += 1
            # trailing comment lines belong to the next block
            k = j
            while k > i + 1 and (lines[k - 1].strip() == "" ):
                k -= 1
            body = lines[i:j]
            out.append(("func", m.group(1), pending + body))
            pending = []
            i = j
            continue
        if line.startswith("#"):
            pending.append(line)
        else:
            if pending:
                out.append(("other", None, pending))
                pending = []
            out.append(("other", None, [line]))
        i += 1
    if pending:
        out.append(("other", None, pending))
    return out


def main(tests_dir, name, rules_path):
    rules = [(s, re.compile(r)) for s, r in json.load(open(rules_path, encoding="utf-8"))]
    path = os.path.join(tests_dir, name + ".gd")
    raw = open(path, encoding="utf-8", newline="").read()
    eol = "\r\n" if "\r\n" in raw else "\n"
    lines = raw.replace("\r\n", "\n").split("\n")
    bl = blocks(lines)
    init = next(b for b in bl if b[0] == "func" and b[1] == "_init")
    entries = re.findall(r"^\t(_check_\w+)\(\)$", "\n".join(init[2]), re.M)
    func_at = next(k for k, l in enumerate(init[2]) if l.startswith("func _init("))
    assert func_at == 0, "_init has a doc comment; handle it by hand"
    tail = [l for l in init[2] if not re.match(r"^\t_check_\w+\(\)$", l)]
    assert "\n".join(tail).count("_check_") == 0
    text_wo_init = "\n".join(l.split("#")[0] for b in bl if b is not init for l in b[2])
    movable = {e for e in entries if len(re.findall(r"\b%s\(" % e, text_wo_init)) == 1}
    subject_of = {}
    for e in entries:
        subject_of[e] = next((s for s, r in rules if r.search(e)), None)
        assert subject_of[e] is not None, "no rule for " + e
    base_lines, subject_funcs = [], {s: [] for s, _ in rules}
    for b in bl:
        if b is init:
            continue
        if b[0] == "func" and b[1] in movable:
            subject_funcs[subject_of[b[1]]].append(b[2])
        else:
            base_lines.extend(b[2])
    # base: header comment says where the checks went
    base_name = re.sub(r"^test_", "", name) + "_base"  # never test_*: runners and review preflight count those
    base_lines.insert(1, "")
    base_lines.insert(2, "## Shared header, helpers and members of the %s* checks (split by subject in R15);" % name)
    base_lines.insert(3, "## the checks themselves live in the %s*.gd files that extend this script." % name)
    while base_lines and base_lines[-1].strip() == "":
        base_lines.pop()
    os.makedirs(os.path.join(tests_dir, "support"), exist_ok=True)
    with open(os.path.join(tests_dir, "support", base_name + ".gd"), "w", encoding="utf-8", newline="") as f:
        f.write(eol.join(base_lines) + eol)
    report = []
    for suffix, _ in rules:
        file_name = name + ("_" + suffix if suffix else "")
        checks = [e for e in entries if subject_of[e] == suffix]
        if not checks:
            continue
        body = ['extends "res://scripts/tests/support/%s.gd"' % base_name, "",
                "## %s checks; shared helpers and the file's full description are in support/%s.gd." % (
                    file_name, base_name), "",
                "func _init() -> void:"]
        body += ["\t%s()" % c for c in checks]
        body += [l.replace('print("%s: PASS")' % name, 'print("%s: PASS")' % file_name) for l in tail[1:]]
        while body[-1].strip() == "":
            body.pop()
        body.append("")
        for fl in subject_funcs[suffix]:
            body.extend(fl)
        while body[-1].strip() == "":
            body.pop()
        with open(os.path.join(tests_dir, file_name + ".gd"), "w", encoding="utf-8", newline="") as f:
            f.write(eol.join(body) + eol)
        report.append("%s: %d checks" % (file_name, len(checks)))
    stay = [e for e in entries if e not in movable]
    print("\n".join(report))
    if stay:
        print("entry checks also called elsewhere, kept in base:", stay)


main(*sys.argv[1:4])

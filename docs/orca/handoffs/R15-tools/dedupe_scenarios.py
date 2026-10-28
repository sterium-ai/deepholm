"""R15: replace verbatim copies of shared scenario builders in test_*.gd with tests/support/scenarios.gd.
A local helper is removed only if its text equals the support function's after normalising the
function name, parameter names (positional) and the WorldType/WorldStateType alias.
Usage: python dedupe_scenarios.py <tests dir>"""
import glob
import os
import re
import sys

OLD_TO_NEW = {
    "_build_world": ["floor_world", "empty_floor_world"],
    "_command": ["command"],
    "_isolate_need": ["isolate_need"],
    "_colonist": ["idle_colonist"],
    "_full_needs": ["full_needs"],
    "_add_stock": ["add_stock"],
    "_jobs_of_kind": ["jobs_of_kind"],
    "_find_job": ["find_job"],
    "_colonist_by_id": ["colonist_by_id"],
    "_find_colonist": ["colonist_by_id"],
}
CONST_LINE = 'const Scenarios = preload("res://scripts/tests/support/scenarios.gd")'


def functions(lines):
    """Yield (start, end, comment_start, name) for top-level funcs; end is exclusive, trailing blanks dropped."""
    i = 0
    while i < len(lines):
        m = re.match(r"(?:static )?func (\w+)\(", lines[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while j < len(lines) and (lines[j].startswith("\t") or lines[j].strip() == ""):
            j += 1
        end = j
        while end > i + 1 and lines[end - 1].strip() == "":
            end -= 1
        c = i
        while c > 0 and lines[c - 1].startswith("##"):
            c -= 1
        yield i, end, c, m.group(1)
        i = j


def normalise(func_lines):
    text = "\n".join(l.rstrip() for l in func_lines)
    text = re.sub(r"^(?:static )?func \w+", "func F", text)
    params = re.match(r"func F\(([^)]*)\)", text).group(1)
    names = [p.split(":")[0].split("=")[0].strip() for p in params.split(",") if p.strip()]
    parts = re.split(r'("(?:[^"\\]|\\.)*")', text)  # odd parts are string literals: left alone
    for k, name in enumerate(names):
        parts = [p if i % 2 else re.sub(r"\b%s\b" % re.escape(name), "p%d" % k, p) for i, p in enumerate(parts)]
    text = "".join(parts)
    return text.replace("WorldType", "WorldStateType")


def main(tests_dir):
    support = open(os.path.join(tests_dir, "support", "scenarios.gd"), encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    reference = {name: normalise(support[s:e]) for s, e, _, name in functions(support)}
    for path in sorted(glob.glob(os.path.join(tests_dir, "test_*.gd"))):
        raw = open(path, encoding="utf-8", newline="").read()
        eol = "\r\n" if "\r\n" in raw else "\n"
        lines = raw.replace("\r\n", "\n").split("\n")
        renames, cuts = {}, []
        for s, e, c, name in functions(lines):
            for new in OLD_TO_NEW.get(name, []):
                if normalise(lines[s:e]) == reference[new]:
                    renames[name] = new
                    cut_end = e
                    while cut_end < len(lines) and lines[cut_end].strip() == "":
                        cut_end += 1
                    cuts.append((c, cut_end))
                    break
        if not renames:
            continue
        for c, e in sorted(cuts, reverse=True):
            del lines[c:e]
        text = "\n".join(lines)
        for old, new in renames.items():
            text, n = re.subn(r"(?<![\w.])%s\(" % re.escape(old), "Scenarios.%s(" % new, text)
            code = "\n".join(l.split("#")[0] for l in text.split("\n"))
            left = re.findall(r"(?<![\w.])%s\b" % re.escape(old), code)
            assert not left, "%s: %s still referenced without a call" % (path, old)
        lines = text.split("\n")
        if CONST_LINE not in lines:
            at = next((k for k, l in enumerate(lines) if re.match(r"const \w+ = preload\(.*\)$", l)), 0)
            lines.insert(at + 1, CONST_LINE)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(eol.join(lines))
        print("%-40s %s" % (os.path.basename(path), ", ".join("%s->%s" % kv for kv in sorted(renames.items()))))


main(sys.argv[1])

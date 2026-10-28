"""List code (not strings, not comments) in GDScript test files that reads a `_private` member
through a receiver, excluding viewer receivers. Usage: python find_privates.py <tests dir> [--all]"""
import glob
import os
import re
import sys

VIEWER = re.compile(r"\b(boot|boot_node|panel|map_view|view|sprites|map|camera|overlay|placeholder_view|trigger|tick_driver|OrderInputType|self|super)\._|_panel_for\(world\)\._")
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
ACCESS = re.compile(r"[\w)\]]\._[a-z]")

root = sys.argv[1]
show_all = "--all" in sys.argv
for path in sorted(glob.glob(os.path.join(root, "*.gd")) + glob.glob(os.path.join(root, "support", "*.gd"))):
    for number, line in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        code = STRING.sub('""', line).split("#")[0]
        if ACCESS.search(code) and (show_all or not VIEWER.search(code)):
            print("%s:%d: %s" % (os.path.relpath(path, root), number, line.strip()[:160]))

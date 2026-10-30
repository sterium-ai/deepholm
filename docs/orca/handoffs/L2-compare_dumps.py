"""L2 evidence: compares a main dump tree with a branch dump tree (L2-dumps.sh).

Both trees' SaveWire record tables ({"$keys": [...]} then rows) are expanded to records first,
then every branch file is read in the pre-L2 shape before comparing: "z" beside every x/y is
dropped, map "layerCount" is dropped, "schemaVersion" 9 reads as 8, and a layer-0 tile printed
as "(x, y, 0)" (a Vector3i) reads as "(x, y)" (the Vector2i it was). A JSON file is compared as
data; a text dump line by line, with the JSON part of "key value" lines compared as data.
Anything still different is printed with its path; a value under a "hash"/"state_hash" key, a
"hash@N" line or a save envelope's "integrity" (the SHA-256 of the state text) is reported
apart, since both cover the added layer fields (ADR 045 §5) and so differ by construction (L2-hash_projection.gd shows the pre-L2 shape of the same
snapshot still hashes to the pre-L2 literals).

usage: python docs/orca/handoffs/L2-compare_dumps.py <main dump dir> <branch dump dir>
exit 0 when nothing but hashes differs.
"""
import json
import os
import re
import sys

TILE3 = re.compile(r'\((-?\d+), (-?\d+), 0\)')


def records(value):
    """value with every SaveWire record table expanded back to its records."""
    if isinstance(value, dict):
        return {key: records(item) for key, item in value.items()}
    if isinstance(value, list):
        if value and isinstance(value[0], dict) and list(value[0].keys()) == ['$keys']:
            keys = value[0]['$keys']
            return [records(dict(zip(keys, row)) if isinstance(row, list) else row) for row in value[1:]]
        return [records(item) for item in value]
    return value


def pre_l2(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if key == 'z' and 'x' in value and 'y' in value:
                continue
            if key == 'layerCount' and ('tiles' in value or 'palette' in value):
                continue
            if key == 'schemaVersion' and item == 9:
                item = 8
            out[pre_l2(key)] = pre_l2(item)
        return out
    if isinstance(value, list):
        return [pre_l2(item) for item in value]
    if isinstance(value, str):
        return TILE3.sub(r'(\1, \2)', value)
    return value


def diff(a, b, path, out):
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b), key=str):
            if key not in a or key not in b:
                out.append((path + [key], a.get(key, '<absent>'), b.get(key, '<absent>')))
            else:
                diff(a[key], b[key], path + [key], out)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append((path + ['<len>'], len(a), len(b)))
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, path + [i], out)
    elif a != b:
        out.append((path, a, b))


def load_lines(path):
    with open(path, encoding='utf-8') as f:
        return f.read().splitlines()


def parse_value(text):
    try:
        return json.loads(text)
    except ValueError:
        return text


def compare_file(main_path, branch_path, rel):
    found = []
    try:
        with open(main_path, encoding='utf-8') as f:
            a = records(json.load(f))
        with open(branch_path, encoding='utf-8') as f:
            b = pre_l2(records(json.load(f)))
        diff(a, b, [rel], found)
        return found
    except ValueError:
        pass
    la, lb = load_lines(main_path), load_lines(branch_path)
    if len(la) != len(lb):
        found.append(([rel, '<lines>'], len(la), len(lb)))
    for i, (x, y) in enumerate(zip(la, lb)):
        kx, _, vx = x.partition(' ')
        ky, _, vy = y.partition(' ')
        key = kx if kx == ky else '%s|%s' % (kx, ky)
        diff(records(parse_value(vx)), pre_l2(records(parse_value(vy))), [rel, 'line %d' % (i + 1), key], found)
    return found


def main():
    main_root, branch_root = sys.argv[1], sys.argv[2]
    hashes, others, files = [], [], 0
    for dirpath, _dirs, names in os.walk(main_root):
        for name in sorted(names):
            if name.endswith('.log'):
                continue
            main_path = os.path.join(dirpath, name)
            rel = os.path.relpath(main_path, main_root).replace('\\', '/')
            branch_path = os.path.join(branch_root, rel)
            files += 1
            if not os.path.exists(branch_path):
                others.append(([rel], 'present', 'missing'))
                continue
            for path, x, y in compare_file(main_path, branch_path, rel):
                is_hash = any(isinstance(p, str) and ('hash' in p.lower() or p == 'integrity') for p in path[1:])
                (hashes if is_hash else others).append((path, x, y))
    print('L2-compare_dumps: %d files, %d hash values differ, %d other differences' % (files, len(hashes), len(others)))
    for path, x, y in others[:50]:
        print('  OTHER %s: main=%s branch=%s' % ('/'.join(str(p) for p in path), str(x)[:120], str(y)[:120]))
    by_file = {}
    for path, _x, _y in hashes:
        by_file[path[0]] = by_file.get(path[0], 0) + 1
    for rel in sorted(by_file):
        print('  hash values differing in %s: %d' % (rel, by_file[rel]))
    sys.exit(0 if not others else 1)


if __name__ == '__main__':
    main()

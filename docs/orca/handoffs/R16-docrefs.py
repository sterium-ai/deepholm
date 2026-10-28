# R16 evidence. Usage (repo root): python docs/orca/handoffs/R16-docrefs.py [doc.md ...]
# Lists function/field references in docs/architecture/*.md that do not resolve to a current
# definition, or that name WorldState as owner of something world_state.gd no longer defines.
import re,glob,os,sys,collections
defs=collections.defaultdict(set)   # name -> files
for p in glob.glob('game/**/*.gd',recursive=True)+glob.glob('tools/**/*.gd',recursive=True):
    p=p.replace(os.sep,'/')
    for l in open(p,encoding='utf-8-sig'):
        m=re.match(r'\s*(?:static\s+)?func\s+(\w+)',l) or re.match(r'\s*(?:@\w+\s+)*(?:var|const|signal)\s+(\w+)',l) or re.match(r'\s*class_name\s+(\w+)',l)
        if m: defs[m.group(1)].add(p)
ws='game/scripts/core/world_state.gd'
files=sys.argv[1:] or sorted(glob.glob('docs/architecture/*.md'))
for f in files:
    if 'bench-baseline' in f: continue
    for i,l in enumerate(open(f,encoding='utf-8'),1):
        for m in re.finditer(r'(WorldState\.|world\.|world_state\.gd[`\s]*[:(]?\s*`?)?`?(_?[a-z][a-z0-9_]*)\(\)',l):
            name=m.group(2); own=m.group(1)
            where=defs.get(name)
            if not where: print(f'{f}:{i}: MISSING {name}()'); continue
            if own and own.startswith(('WorldState','world.','world_state')) and ws not in where:
                print(f'{f}:{i}: NOT-IN-WS {name}() -> {sorted(where)[:2]}')
        for m in re.finditer(r'(WorldState\.|world\.)(_[a-z][a-z0-9_]*)\b(?!\()',l):
            name=m.group(2); where=defs.get(name,set())
            if ws not in where: print(f'{f}:{i}: FIELD {m.group(0)} -> {sorted(where)[:2]}')
        for m in re.finditer(r'`(_events|_items|_tiles|_objects)`|\b(_events|_items|_tiles|_objects)\b',l):
            print(f'{f}:{i}: BANNED {m.group(0)}')

# R16 evidence. Usage (repo root): python docs/orca/handoffs/R16-docrefs.py [file ...]
# Lists function/field references that do not resolve to a current definition, that name
# WorldState as owner of something world_state.gd no longer defines, or that name another class
# (`Class.fn()` / `Class._field`) whose file does not define it. A class is a `class_name` or
# a file's CamelCase name (state_codec.gd -> StateCodec). Default: docs/architecture/*.md and
# the README.md files under game/scripts/core.
import re,glob,os,sys,collections
defs=collections.defaultdict(set)   # name -> files
members=collections.defaultdict(set) # file -> names it defines
classes={}                           # class name -> file
def camel(stem): return ''.join(w.capitalize() for w in stem.split('_'))
for p in glob.glob('game/**/*.gd',recursive=True)+glob.glob('tools/**/*.gd',recursive=True):
    p=p.replace(os.sep,'/')
    classes.setdefault(camel(os.path.basename(p)[:-3]),p)
    for l in open(p,encoding='utf-8-sig'):
        m=re.match(r'\s*class_name\s+(\w+)',l)
        if m: classes[m.group(1)]=p
        m=re.match(r'\s*(?:static\s+)?func\s+(\w+)',l) or re.match(r'\s*(?:@\w+\s+)*(?:var|const|signal)\s+(\w+)',l)
        if m: defs[m.group(1)].add(p); members[p].add(m.group(1))
ws='game/scripts/core/world_state.gd'
GODOT={'randi','new','dispose','tr','parse_string','from_native','to_native','stringify','call','bind'}
files=sys.argv[1:] or sorted(glob.glob('docs/architecture/*.md'))+sorted(glob.glob('game/scripts/core/**/README.md',recursive=True))
for f in files:
    f=f.replace(os.sep,'/')
    if 'bench-baseline' in f: continue
    for i,l in enumerate(open(f,encoding='utf-8'),1):
        for m in re.finditer(r'(WorldState\.|world\.|world_state\.gd[`\s]*[:(]?\s*`?)?`?(_?[a-z][a-z0-9_]*)\(\)',l):
            name=m.group(2); own=m.group(1)
            where=defs.get(name)
            if not where:
                if name not in GODOT: print(f'{f}:{i}: MISSING {name}()')
                continue
            if own and own.startswith(('WorldState','world.','world_state')) and ws not in where:
                print(f'{f}:{i}: NOT-IN-WS {name}() -> {sorted(where)[:2]}')
        for m in re.finditer(r'(WorldState\.|world\.)(_[a-z][a-z0-9_]*)\b(?!\()',l):
            name=m.group(2); where=defs.get(name,set())
            if ws not in where: print(f'{f}:{i}: FIELD {m.group(0)} -> {sorted(where)[:2]}')
        for m in re.finditer(r'\b([A-Z][A-Za-z0-9]+)\.(_?[a-z][a-z0-9_]*)\b',l):
            cls,name=m.group(1),m.group(2)
            if cls=='WorldState' or cls not in classes or name in GODOT: continue
            if name not in members[classes[cls]]:
                print(f'{f}:{i}: WRONG-OWNER {cls}.{name} -> {sorted(defs.get(name,[]))[:2] or "undefined"}')
        for m in re.finditer(r'\b(_events|_items|_tiles|_objects)\b',l):
            print(f'{f}:{i}: BANNED {m.group(0)}')

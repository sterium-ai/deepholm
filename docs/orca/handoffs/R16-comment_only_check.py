# R16 evidence. Usage (repo root): python docs/orca/handoffs/R16-comment_only_check.py [base-commit]
# Strict: non-comment, non-blank lines must be identical to BASE, except NEW lines starting with
# "assert(" may be added. Existing asserts must all remain, in order.
import subprocess,sys,difflib
base=sys.argv[1] if len(sys.argv)>1 else '691c25e'
files=subprocess.run(['git','diff','--name-only',base,'--','game/scripts/core'],capture_output=True,text=True,encoding='utf-8').stdout.split()
def code(t): return [l.rstrip() for l in t.split('\n') if l.strip() and not l.strip().startswith('#')]
bad=0
for f in files:
    if not f.endswith('.gd'): continue
    a=code(subprocess.run(['git','show',f'{base}:{f}'],capture_output=True,text=True,encoding='utf-8').stdout)
    b=code(open(f,encoding='utf-8').read())
    sm=difflib.SequenceMatcher(None,a,b,autojunk=False)
    for op,i1,i2,j1,j2 in sm.get_opcodes():
        if op=='equal': continue
        if op=='insert' and all(x.strip().startswith('assert(') for x in b[j1:j2]):
            print('assert added',f,b[j1:j2]); continue
        bad+=1; print('CHANGED',f,op,a[i1:i2][:3],'->',b[j1:j2][:3])
print(len(files),'files;',bad,'code changes'); sys.exit(1 if bad else 0)

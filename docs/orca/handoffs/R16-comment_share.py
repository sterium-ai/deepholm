# R16 evidence: share of full-line comments in game/scripts/core (the acceptance metric).
# Same rule as tools/measure_core.ps1 (a line whose trimmed text starts with "#"), core only (no boot.gd).
# Usage (repo root): python docs/orca/handoffs/R16-comment_share.py [rows]
import os,sys
root='game/scripts/core'
T=C=0;rows=[]
for d,_,fs in os.walk(root):
  for f in fs:
    if f.endswith('.gd'):
      p=os.path.join(d,f).replace(os.sep,'/')
      L=open(p,encoding='utf-8-sig').read().split('\n')
      if L and L[-1]=='': L=L[:-1]
      c=sum(1 for l in L if l.strip().startswith('#'))
      T+=len(L);C+=c;rows.append((c,len(L),p))
rows.sort(reverse=True)
for r in rows[:int(sys.argv[1]) if len(sys.argv)>1 else 40]: print(r)
print('total',T,'comment',C,'pct',round(100*C/T,2),'files',len(rows))

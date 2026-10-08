import hashlib,json,re,subprocess
from pathlib import Path
bundle=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/acceptance/B16/candidate.app')
magic={bytes.fromhex(x) for x in ['cffaedfe','cefaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
def out(*a):
 p=subprocess.run(a,text=True,capture_output=True);return {'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
 return h.hexdigest()
roots=[]
for p in sorted(bundle.rglob('*')):
 if p.is_file():
  with p.open('rb') as f:b=f.read(4)
  if b in magic:roots.append(p)
records={};edges=[];unresolved=[]
def visit(p,exe,ancestry):
 p=p.resolve();key=str(p)
 if key in ancestry:return
 if key not in records:
  libs=out('/usr/bin/otool','-L',key);load=out('/usr/bin/otool','-l',key)
  records[key]={'sha256':sha(p),'architecture':out('/usr/bin/lipo','-archs',key),'signature':out('/usr/bin/codesign','-dv','--verbose=4',key),'libraries':libs,'load_commands':load}
 r=records[key];rpaths=re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset',r['load_commands']['stdout'])
 def expand(v):return v.replace('@loader_path',str(p.parent)).replace('@executable_path',str(exe.parent))
 for line in r['libraries']['stdout'].splitlines()[1:]:
  dep=line.strip().split(' (compatibility version')[0]
  if dep==key:continue
  edge={'from':key,'dependency':dep,'executable_context':str(exe)}
  if dep.startswith(('/System/Library/','/usr/lib/')):edge['boundary']='system dyld shared cache / system library; not recursively inspected'
  else:
   candidates=[Path(expand(dep))] if not dep.startswith('@rpath/') else [Path(expand(x))/dep[7:] for x in rpaths]
   resolved=next((x.resolve() for x in candidates if x.is_file()),None)
   edge['candidates']=[str(x) for x in candidates]
   if resolved:
    edge['resolved']=str(resolved);edge['bundled']=resolved.is_relative_to(bundle);visit(resolved,exe,ancestry|{key})
   else:unresolved.append(edge)
  edges.append(edge)
for p in roots:visit(p,p,set())
report={'scope':'B16 frozen app Mach-O images and recursively resolved non-system dependencies; system shared cache treated as boundary','roots':[str(p) for p in roots],'images':records,'edges':edges,'unresolved':unresolved,'external_non_system_images':[k for k in records if not Path(k).is_relative_to(bundle)],'hermetic':not unresolved and all(Path(k).is_relative_to(bundle) for k in records),'required_local_escalator_present':(bundle/'Contents/MacOS/vphone-escalator').exists(),'system_cache_closure_verified':False}
Path('/private/tmp/vphone-b19-dependency-audit.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ['roots','external_non_system_images','unresolved','hermetic','required_local_escalator_present']},indent=2))

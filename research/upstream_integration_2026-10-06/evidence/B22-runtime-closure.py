import hashlib,json,os,plistlib,re,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
roots=[r/'.build/acceptance/B21/relay-diagnostic.app',r/'.build/acceptance/B15/helper-client.app',r/'.build/acceptance/B13/helper-client.app']
magic={b'\xfe\xed\xfa\xce',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}
def run(*args):
 p=subprocess.run(args,capture_output=True,text=True);return {'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
nodes={};pending=[];bundle_rows=[]
for root in roots:
 assert root.is_dir()
 bundle_rows.append({'path':str(root),'signature':run('/usr/bin/codesign','--verify','--strict','--deep',str(root)),'info':plistlib.loads((root/'Contents/Info.plist').read_bytes())})
 for p in root.rglob('*'):
  if not p.is_file() or p.is_symlink():continue
  with p.open('rb') as f:head=f.read(4)
  if head not in magic:continue
  load=run('/usr/bin/xcrun','vtool','-show-build',str(p))
  if 'platform IOS' in load['stdout'] or 'platform IOSSIMULATOR' in load['stdout']:continue
  pending.append((p,p.parent))
while pending:
 p,executable_dir=pending.pop(0);key=str(p.resolve())
 if key in nodes:continue
 assert p.is_file()
 out=run('/usr/bin/otool','-L',str(p));assert out['returncode']==0,out
 commands=run('/usr/bin/otool','-l',str(p));rpaths=re.findall(r'cmd LC_RPATH\n.*?path (.*?) \(offset',commands['stdout'],re.S)
 # Limit each match to its own load command (otool emits cmd LC_RPATH before path).
 rpaths=[x.splitlines()[-1].strip() for x in rpaths]
 node={'path':str(p),'resolved_path':key,'sha256':sha(p),'architecture':run('/usr/bin/lipo','-archs',str(p)),'build':run('/usr/bin/xcrun','vtool','-show-build',str(p)),'signature':run('/usr/bin/codesign','--verify','--strict',str(p)),'rpaths':rpaths,'dependencies':[]}
 nodes[key]=node
 def expand(s):return s.replace('@loader_path',str(p.parent)).replace('@executable_path',str(executable_dir))
 for line in out['stdout'].splitlines()[1:]:
  raw=line.strip().split(' (compatibility version ')[0]
  if raw==str(p) or raw==key:continue
  if raw.startswith(('/usr/lib/','/System/Library/')):node['dependencies'].append({'install_name':raw,'source':'macOS system image or dyld shared cache'});continue
  candidates=[Path(expand(x))/raw[len('@rpath/'):] for x in rpaths] if raw.startswith('@rpath/') else [Path(expand(raw))]
  existing=[x for x in candidates if x.is_file()]
  if not existing:node['dependencies'].append({'install_name':raw,'unresolved':True,'candidates':list(map(str,candidates))});continue
  child=existing[0];node['dependencies'].append({'install_name':raw,'path':str(child),'resolved_path':str(child.resolve()),'source':'bundled' if any(child.resolve().is_relative_to(x.resolve()) for x in roots) else 'external'})
  pending.append((child,executable_dir))
unresolved=[{'image':n['path'],**d} for n in nodes.values() for d in n['dependencies'] if d.get('unresolved')]
report={'bundles':bundle_rows,'host_images':list(nodes.values()),'unresolved_non_system_dependencies':unresolved,'external_images':[x for x in nodes.values() if not any(Path(x['resolved_path']).is_relative_to(y.resolve()) for y in roots)],'os':run('/usr/bin/sw_vers'),'system_images_are_os_supplied':True,'portable_distribution_claimed':False,'all_non_system_edges_resolved':not unresolved}
Path('/private/tmp/vphone-b22-runtime-closure.json').write_text(json.dumps(report,indent=2)+'\n');print({'host_images':len(nodes),'external':len(report['external_images']),'unresolved':unresolved})
assert not unresolved

from pathlib import Path
import subprocess,json,hashlib,plistlib,re
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
apps=[r/'.build/vphone-cli.app',r/'.build/vphone-launchpad.app']
rows=[]
for app in apps:
 subprocess.run(['codesign','--verify','--strict','--deep',str(app)],check=True,capture_output=True)
 for p in sorted((app/'Contents/MacOS').iterdir()):
  if not p.is_file():continue
  details=subprocess.run(['codesign','-dvvv',str(p)],check=True,capture_output=True,text=True).stderr
  d=p.read_bytes(); row={'path':str(p.relative_to(r)),'bytes':len(d),'sha256':hashlib.sha256(d).hexdigest(),'cdhash':re.search(r'^CDHash=(.+)$',details,re.M).group(1)}
  row['linked_libraries']=subprocess.check_output(['otool','-L',str(p)],text=True).splitlines()[1:]
  rows.append(row)
info=plistlib.loads((apps[0]/'Contents/Info.plist').read_bytes());assert info['VPhoneBoundLaunchProtocol']=='vphone.local-bound-launch.v1'
info2=plistlib.loads((apps[1]/'Contents/Info.plist').read_bytes())
keys=['NSLocationUsageDescription','NSLocationWhenInUseUsageDescription','NSLocationAlwaysAndWhenInUseUsageDescription']
assert all(isinstance(info2.get(k),str) and info2[k] for k in keys)
out={'source_base':subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip(),'working_tree_changes':True,'strict_deep_signature_verified':[str(x.relative_to(r)) for x in apps],'binaries':rows,'bound_vm_protocol':info['VPhoneBoundLaunchProtocol'],'location_keys':{k:info2[k] for k in keys},'execution':'No new host VM binary was executed; no new AMFI scope was applied.','external_dependency_limit':'Homebrew libcrypto/libplist remain external where listed by otool; full portable closure is pending.'}
Path('/private/tmp/vphone-b21-final-artifacts.json').write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'verified_apps':len(apps),'binaries':len(rows),'host_execution':False}))

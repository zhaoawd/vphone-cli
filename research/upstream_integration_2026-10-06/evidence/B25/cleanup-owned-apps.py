from pathlib import Path
import subprocess,hashlib,json,shutil,os
base=Path('/private/tmp/vphone-b25');dest=base/'retained-ui-mach-o';dest.mkdir(exist_ok=True)
paths=[Path('/private/tmp/vphone-b25-t46')/name for name in ('source-current-launchpad.app','T46-normal.app','T46-escaped.app')]+[Path('/private/tmp/vphone-b25-t24/portable-vphone-cli.app')]
ps=subprocess.check_output(['ps','-axo','pid,command'],text=True)
rows=[]
for app in paths:
 assert app.is_dir() and not app.is_symlink() and app.stat().st_uid==os.getuid()
 assert not any(str(app)+'/Contents/' in line and 'python' not in line for line in ps.splitlines()),str(app)
 allocated=int(subprocess.check_output(['du','-sk',str(app)],text=True).split()[0])*1024
 row={'path':str(app),'allocated_bytes':allocated,'retained':[]}
 signature=subprocess.run(['codesign','-dvvv',str(app)],text=True,capture_output=True)
 row['signature']={'exit':signature.returncode,'stderr':signature.stderr}
 if app.name in ('T46-normal.app','T46-escaped.app'):
  for relative in ('Contents/MacOS/vphone-launchpad','Contents/Info.plist','Contents/Resources/embedded-toolchain.json','Contents/_CodeSignature/CodeResources','Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli'):
   p=app/relative;target=dest/app.stem/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
   row['retained'].append({'path':str(target),'bytes':target.stat().st_size,'sha256':hashlib.sha256(target.read_bytes()).hexdigest()})
 shutil.rmtree(app);row['removed']=not app.exists();rows.append(row)
(base/'cleanup.json').write_text(json.dumps({'rows':rows,'removed_allocated_bytes':sum(x['allocated_bytes'] for x in rows),'retained_bytes':sum(f['bytes'] for x in rows for f in x['retained']),'failure_evidence_deleted':False},indent=2)+'\n');print(json.dumps({'removed_allocated_bytes':sum(x['allocated_bytes'] for x in rows),'retained_bytes':sum(f['bytes'] for x in rows for f in x['retained'])}))

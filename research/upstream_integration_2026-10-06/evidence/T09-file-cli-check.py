import json,hashlib,subprocess,tempfile,os,fcntl,plistlib
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
binary=root/'.build/debug/vphone-cli'; rows=[]
sha=lambda b:hashlib.sha256(b).hexdigest()
def invoke(label,file,args=(),failure=False):
 p=subprocess.run([str(binary),'fw','selection-migrate',str(file),*args],capture_output=True,text=True,timeout=30)
 rows.append({'case':label,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 if failure:
  assert p.returncode!=0 and not p.stdout.strip(),(label,p.stdout,p.stderr)
  return None
 assert p.returncode==0,(label,p.stdout,p.stderr)
 return json.loads(p.stdout)
with tempfile.TemporaryDirectory(prefix='vphone-selection-file-cli-',dir='/private/tmp') as folder:
 base=Path(folder)
 def fixture(name):
  d=base/name;d.mkdir();f=d/'PatchSelection.plist'
  data=plistlib.dumps({'Preset':'extended','AllowedPatches':['ibss.serial_label'],'BlockedPatches':['kernel-exp-paravirt_user_clients']},fmt=plistlib.FMT_XML)
  f.write_bytes(data);os.chmod(f,0o640)
  (d/'config.plist').write_bytes(b'local variant exp remains unchanged\n')
  return d,f,data
 d,f,original=fixture('normal');sentinel=(d/'config.plist').read_bytes()
 preview=invoke('preview',f)
 assert preview['sourceSHA256']==sha(original) and preview['changed'] is True
 assert preview['migratedPreset']=='experimental'
 assert preview['selection']['blocked']==['kernel-cfw-paravirt_user_clients']
 assert preview['selection']['notDeclaredLocally']==['kernel-cfw-paravirt_user_clients']
 assert f.read_bytes()==original and len(list(d.iterdir()))==2
 result=invoke('apply',f,['--apply','--expected-source-sha256',sha(original)])
 assert result['changed'] is True
 assert Path(result['backupPath']).read_bytes()==original
 assert result['outputSHA256']==preview['outputSHA256']==sha(f.read_bytes())
 parsed=plistlib.loads(f.read_bytes())
 assert parsed=={'Preset':'experimental','AllowedPatches':['ibss-cfw-serial_label'],'BlockedPatches':['kernel-cfw-paravirt_user_clients']}
 assert (f.stat().st_mode & 0o777)==0o640 and (d/'config.plist').read_bytes()==sentinel
 before=f.stat(); names=sorted(p.name for p in d.iterdir())
 no_op=invoke('repeated-apply',f,['--apply','--expected-source-sha256',sha(f.read_bytes())])
 assert no_op['changed'] is False and f.stat().st_ino==before.st_ino and f.stat().st_mtime_ns==before.st_mtime_ns
 assert sorted(p.name for p in d.iterdir())==names
 # Restore bytes from the preserved original for a controlled rollback check.
 rollback=f.with_name('.restore-original');rollback.write_bytes(Path(result['backupPath']).read_bytes());os.replace(rollback,f)
 assert f.read_bytes()==original and (d/'config.plist').read_bytes()==sentinel
 rows.append({'case':'original-byte-rollback','exit_code':0})
 for name in ['stale','busy','missing-digest','backup-conflict','pending','unknown-key','corrupt','entity','link']:
  d,f,original=fixture(name);digest=sha(original)
  args=['--apply','--expected-source-sha256',digest]
  if name=='stale':
   altered=plistlib.dumps({'Preset':'extended','AllowedPatches':['ibec.serial_label'],'BlockedPatches':[]})
   f.write_bytes(altered);original=altered
  if name=='missing-digest':args=['--apply']
  if name=='backup-conflict':(d/f'PatchSelection.plist.before-id-migration-{digest}.bak').write_bytes(b'unrelated file')
  if name=='pending':(d/'.firmware-transaction').mkdir()
  if name=='unknown-key':
   values=plistlib.loads(original);values['SchemaVersion']=99;original=plistlib.dumps(values);f.write_bytes(original);args[-1]=sha(original)
  if name=='corrupt':original=b'broken plist';f.write_bytes(original);args[-1]=sha(original)
  if name=='entity':
   original=b'<?xml version="1.0"?><!DOCTYPE plist [<!ENTITY custom "extended">]><plist version="1.0"><dict><key>Preset</key><string>&custom;</string><key>AllowedPatches</key><array/><key>BlockedPatches</key><array/></dict></plist>'
   f.write_bytes(original);args[-1]=sha(original)
  if name=='link':
   target=d/'original.plist';f.rename(target);f.symlink_to(target)
  if name=='busy':
   fd=os.open(d,os.O_RDONLY|os.O_DIRECTORY);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
   try:invoke(name,f,args,True)
   finally:fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)
  else:invoke(name,f,args,True)
  assert f.read_bytes()==original and (d/'config.plist').read_bytes()==sentinel,name
  assert not any(p.name.startswith('.PatchSelection.plist.migrate-') for p in d.iterdir()),name
Path('/private/tmp/vphone-t09-file-cli-check-20261007.json').write_text(json.dumps({'passed':True,'count':len(rows),'cases':rows,'scope':'temporary synthetic files only; no VM operations'},ensure_ascii=False,indent=2)+'\n')
print(f'{len(rows)} CLI/rollback cases passed; config sentinel unchanged')

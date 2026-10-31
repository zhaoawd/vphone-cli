"""Wait for the scoped handback, then run the sequential acceptance once."""
import datetime,hashlib,json,os,time
from pathlib import Path
r=Path('/Users/kolar/github/vphone-cli');d=r/'.build/t32-resume-acceptance-20261020'
status=d/'launcher-state.json'
def save(state,**values):status.write_text(json.dumps(dict(state=state,launcherPID=os.getpid(),recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),**values),indent=2)+'\n')
save('waiting-handback')
try:
 deadline=time.monotonic()+43200
 while time.monotonic()<deadline:
  p=r/'.build/t32-resume-20261020/handback-result.json'
  if p.exists() and p.stat().st_size:
   result=json.loads(p.read_text())
   if result.get('state')!='passed':raise ValueError('scoped handback did not pass')
   break
  time.sleep(5)
 else:raise TimeoutError('scoped handback has not completed within 12 hours')
 manifest=json.loads((d/'input-manifest.json').read_text())
 for name,expected in manifest.items():
  if hashlib.sha256((r/name).read_bytes()).hexdigest()!=expected:raise ValueError('input changed: '+name)
 vm=r/'vm-t32-t33-dsc-20261018';s=(vm/'Disk.img').lstat()
 if (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)!=(16777231,247084001,68719476736,1792408052355107733):raise ValueError('disk identity changed since isolated preparation')
 if any(vm.glob('.cfw_disk.*')) or any(vm.glob('.cfw_mount.*')):raise ValueError('another transaction exists')
 save('exec-sequential-acceptance')
 os.chdir(r);os.execv(str(r/'.venv/bin/python3'),[str(r/'.venv/bin/python3'),'-u',str(d/'run-acceptance.py')])
except Exception as error:
 save('failed',error=str(error));raise

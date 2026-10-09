from pathlib import Path
import hashlib,json,os,stat,subprocess,time
source=Path('/Users/qcz3840/github/vphone-cli/vm.backups/b18-vm-new-fixed-binding-20261008')
target=Path('/Users/qcz3840/github/vphone-cli/vm.backups/b21-restored-vm-new-20261009')
original=Path('/Users/qcz3840/github/vphone-cli/vm-new')
assert not target.exists()
assert os.statvfs(source).f_bavail*os.statvfs(source).f_frsize>=12*1024**3
for root in (source,original):
 files=[str(p) for p in root.rglob('*') if p.is_file()]
 check=subprocess.run(['/usr/sbin/lsof','-t','--',*files],text=True,capture_output=True)
 assert check.returncode==1 and not check.stdout.strip()
subprocess.run(['/bin/cp','-cR',str(source),str(target)],check=True)
def inventory(root):
 out={}
 for p in sorted(root.rglob('*')):
  s=p.lstat(); name=str(p.relative_to(root))
  assert stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode),name
  if stat.S_ISREG(s.st_mode):
   h=hashlib.sha256()
   with p.open('rb') as f:
    while True:
     data=f.read(1024*1024)
     if not data:break
     h.update(data)
   out[name]={'bytes':s.st_size,'sha256':h.hexdigest(),'mode':oct(stat.S_IMODE(s.st_mode))}
 return out
start=time.monotonic(); before=inventory(source); restored=inventory(target)
assert before==restored
result={'source':str(source),'target':str(target),'method':'APFS clone restore; original VM stopped; identity-preserving recovery, not concurrent clone','files':restored,'full_inventory_equal':True,'seconds':time.monotonic()-start}
Path('/private/tmp/vphone-b21-restore.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'full_inventory_equal':True,'files':len(before),'seconds':result['seconds']}),flush=True)

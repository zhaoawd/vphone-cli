import os,hashlib,json,fcntl,time
from pathlib import Path
src=Path('/Users/qcz3840/github/vphone-cli/vm-new'); dst=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
r={}; handles=[]
for root in (src,dst):
 fd=os.open(root,os.O_RDONLY);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);handles.append(fd)
 files={}
 for name in ['Disk.img','nvram.bin','SEPStorage','config.plist','AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin']:
  p=root/name; before=p.stat();h=hashlib.sha256()
  with p.open('rb') as f:
   while b:=f.read(16<<20):h.update(b)
  after=p.stat();assert (before.st_ino,before.st_size,before.st_mtime_ns)==(after.st_ino,after.st_size,after.st_mtime_ns)
  files[name]={'sha256':h.hexdigest(),'inode':before.st_ino,'size':before.st_size}
 r[str(root)]=files
 print(str(root),flush=True)
r['all_content_equal']=all(r[str(src)][n]['sha256']==r[str(dst)][n]['sha256'] for n in r[str(src)])
Path('research/evidence/2026-10-13-task8/acceptance/baseline-digests.json').write_text(json.dumps(r,indent=2)+'\n')
print('all_content_equal',r['all_content_equal'],flush=True)

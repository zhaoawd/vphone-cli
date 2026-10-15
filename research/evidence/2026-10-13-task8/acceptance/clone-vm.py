import os,fcntl,subprocess,json,time,hashlib
from pathlib import Path
repo=Path('/Users/qcz3840/github/vphone-cli')
source=repo/'vm-new'
root=Path('/private/tmp/vphone-task8-acceptance-vms')
target=root/'task8-copy'
evidence=repo/'research/evidence/2026-10-13-task8/acceptance'
root.mkdir(mode=0o700,exist_ok=True)
if target.exists():raise RuntimeError('test copy already exists; refuse replace')
fd=os.open(source,os.O_RDONLY|os.O_DIRECTORY);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
names=['Disk.img','nvram.bin','SEPStorage','config.plist','AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin']
def sig(p):
 s=p.stat();return {'device':s.st_dev,'inode':s.st_ino,'size':s.st_size,'mtime_ns':s.st_mtime_ns,'ctime_ns':s.st_ctime_ns,'allocated':s.st_blocks*512}
before={n:sig(source/n) for n in names}
r=subprocess.run(['/bin/cp','-cR',str(source),str(target)],capture_output=True,text=True)
after={n:sig(source/n) for n in names}
record={'source':str(source),'target':str(target),'command':['cp','-cR',str(source),str(target)],'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'source_before':before,'source_after':after,'source_metadata_unchanged':before==after}
if r.returncode==0:
 record['target_files']={n:sig(target/n) for n in names}
 record['disk_inode_distinct']=sig(source/'Disk.img')['inode']!=sig(target/'Disk.img')['inode']
(evidence/'clone.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({k:v for k,v in record.items() if not isinstance(v,dict)},indent=2))
assert r.returncode==0 and before==after and record['disk_inode_distinct']

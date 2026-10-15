from pathlib import Path
import hashlib,json,os,fcntl,sys
r=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy');e=Path('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance');baseline=json.loads((e/'baseline-digests.json').read_text())[str(r)]
fd=os.open(r,os.O_RDONLY);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);d={}
for name,old in baseline.items():
 p=r/name;h=hashlib.sha256()
 with p.open('rb') as f:
  while b:=f.read(16<<20): h.update(b)
 d[name]={'sha256':h.hexdigest(),'baseline_sha256':old['sha256'],'same_content':h.hexdigest()==old['sha256'],'inode_unchanged':p.stat().st_ino==old['inode']}
out={'files':d,'all_content_unchanged':all(v['same_content'] for v in d.values()),'disk_inode_unchanged':d['Disk.img']['inode_unchanged'],'binding_unchanged':(r/'launchpad.json').read_bytes()==(e/(sys.argv[2] if len(sys.argv)>2 else 'binding-before-update.json')).read_bytes(),'pending_transaction':(r/'.firmware-transaction').exists()};(e/((sys.argv[1] if len(sys.argv)>1 else 'kernel-failure-recovery-readback')+'.json')).write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out))

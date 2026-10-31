"""Read only the interrupted transaction record and filesystem identities."""
import json,os,stat,hashlib,subprocess
from pathlib import Path
R=Path('/Users/kolar/github/vphone-cli');B=R/'.build/t32-t33-completion-20261023';V=R/'.build/t33t-20261025';W=B/'exp-plist-lifetime-acceptance-20261025';O=B/'f430-interruption-inspection-20261026.json'
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def meta(p):
 s=p.lstat();return dict(dev=s.st_dev,ino=s.st_ino,bytes=s.st_size,mtime_ns=s.st_mtime_ns,mode=stat.S_IMODE(s.st_mode),uid=s.st_uid,gid=s.st_gid)
x=dict(scope='readonly interrupted transaction metadata',VMStarts=0,CFWRetries=0,transactionWrites=0,uid=os.geteuid(),pending=[])
for p in sorted(V.glob('.cfw_disk.*')):
 d=dict(path=str(p),identity=meta(p))
 q=p/'transaction.json'
 if q.exists():d.update(record=json.loads(q.read_bytes()),recordSHA256=sha(q))
 for name in ('Disk.img','guest-publication.json','guest-final-effects.json','guest-undo-request.json'):
  q=p/name
  if q.exists():d.setdefault('files',{})[name]=meta(q)
 d['members']=[q.name for q in p.iterdir()];x['pending'].append(d)
x['currentDisk']=meta(V/'Disk.img');x['binding']=json.loads((V/'launchpad.json').read_bytes())
x['processes']=subprocess.run(['/bin/ps','-p','74293','-o','uid=,lstart=,command='],capture_output=True,text=True).__dict__.get('stdout')
with O.open('x') as f:json.dump(x,f,indent=2);f.write('\n')
os.chmod(O,0o644)
print(json.dumps(dict(output=str(O),pending=len(x['pending']),VMStarts=0,transactionWrites=0)))

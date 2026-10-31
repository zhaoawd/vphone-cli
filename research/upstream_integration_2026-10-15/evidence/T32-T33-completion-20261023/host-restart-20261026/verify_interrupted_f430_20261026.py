"""Fresh readonly disk/target observations; never reinterpret historical authority."""
import json,os,sys,hashlib,fcntl,plistlib,subprocess,time
from pathlib import Path
R=Path('/Users/kolar/github/vphone-cli');sys.path.insert(0,str(R/'scripts'))
import cfw_verify_effects as audit
import cfw_guest_evidence as evidence
import cfw_disk_txn as txn
B=R/'.build/t32-t33-completion-20261023';W=B/'exp-plist-lifetime-acceptance-20261025';V=R/'.build/t33t-20261025';S=V/'.cfw_disk.W7aZSh3x';O=B/'f430-interruption-readback-20261026.json'
def sha(p):return evidence.digest(p)
def observe(image,expected):
 txn.require_unheld(image,os.getpid(),'interrupted readonly readback')
 start=time.monotonic();digest=sha(image)
 print(json.dumps(dict(step='complete-disk-read',image=str(image),sha256=digest,elapsedSeconds=time.monotonic()-start)),flush=True)
 wanted={r['target'].split(':',1)[0] for r in expected};wanted.discard('dsc');wanted.add('system')
 with audit.readonly_roots(image,wanted,Path('/private/tmp')) as (roots,recheck):
  compared=audit.installed_effects.verify_targets(expected,roots);recheck()
 rows=compared['targets']
 return dict(sha256=digest,identity=evidence.image_identity(image.stat()),targetCount=len(rows),matchedTargets=sum(r['matches'] is True for r in rows),passed=compared['passed'],mismatches=[r for r in rows if r['matches'] is not True][:20],elapsedSeconds=time.monotonic()-start)
fd=os.open(V,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
 on=json.loads(evidence.read(W/'execution/exp/on.json',maximum=100<<20))
 final=json.loads(evidence.read(S/evidence.FINAL,maximum=100<<20))
 record=json.loads(evidence.read(S/'transaction.json'))
 if record['status']!='staged' or record.get('guestEvidenceSHA256') or record['id']!='20261025T144138Z-W7aZSh3x':raise ValueError('Interrupted scope changed')
 current=observe(V/'Disk.img',[dict(target=r['target'],state=r['expected']) for r in on['independentAudit']['targets']])
 if current['sha256']!=on['independentAudit']['currentImageSHA256']:raise ValueError('Current full disk differs from published first-on')
 staged=observe(S/'Disk.img',final['outputs'])
 plan=json.loads(evidence.read(W/'offline-plan.json'));inputs=json.loads(evidence.read(W/'executor-inputs.json'))
 for name,digest in dict(plan['frozenInputs'],**inputs['files']).items():
  if sha(Path(name))!=digest:raise ValueError('Frozen source changed: '+name)
 private=sha(V/'.firmware-desired-plan.json')
 if private!='3badc4d1963fc2d2e56e99a31ebb30d5912ea189f2f5a21348f8b0a4771c74ce':raise ValueError('Desired plan changed')
 volume=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist','/System/Volumes/Data']))
 x=dict(scope='fresh readonly bytes and metadata observations after host restart',current=current,staged=staged,privateDesiredSHA256=private,planInputs=len(plan['frozenInputs']),executionInputs=len(inputs['files']),allFrozenInputHashesPassed=True,volume={k:v for k,v in volume.items() if 'UUID' in k},historicalDevice=record['original']['dev'],currentDevice=os.stat(V/'Disk.img').st_dev,historicalRecordsRewritten=False,publicationQualified=False,VMStarts=0,CFWRetries=0,transactionWrites=0)
 with O.open('x') as f:json.dump(x,f,indent=2);f.write('\n')
 os.chmod(O,0o644);print(json.dumps(x),flush=True)
finally:os.close(fd)

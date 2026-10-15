"""Run the formal host-binding command and verify its limited metadata boundary."""
from pathlib import Path
import json,hashlib,subprocess,sys,re,plistlib,stat
E=Path(__file__).resolve().parent;VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
CLI='/Library/Application Support/vphone-launchpad/Bundles/2.6.20261021-local/VPhone.bundle/Contents/MacOS/vphone-cli'
assert len(sys.argv)==3 and re.fullmatch(r'[a-z0-9-]+',sys.argv[1])
label,target=sys.argv[1:];assert target in ('2.6.20261021-local','2.6.20261016-local')
out=E/(label+'-host-rebind-check.json');output=out.open('x');r={'passed':False,'target_version':target}
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def observe():
    assert not (VM/'.firmware-transaction').exists() and not (VM/'.firmware-desired-pending.json').exists()
    attachments=[i for i in plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist'])).get('images',[]) if 'vphone-task8-acceptance-vms' in i.get('image-path','')];assert not attachments
    binding=json.loads((VM/'launchpad.json').read_text());receipt=json.loads((VM/'.firmware-component-receipts.json').read_text());tx=receipt['transactionID'];assert re.fullmatch(r'[0-9a-f-]{36}',tx)
    archive=VM/'.firmware-history'/tx
    names=['Disk.img','nvram.bin','SEPStorage','config.plist','AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin']
    metadata={}
    for name in names:
        s=(VM/name).lstat();assert stat.S_ISREG(s.st_mode)
        metadata[name]={k:getattr(s,k) for k in ('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns')}
    return {'binding':binding,'binding_sha256':digest(VM/'launchpad.json'),'receipt_sha256':digest(VM/'.firmware-component-receipts.json'),'desired_sha256':digest(VM/'.firmware-desired-plan.json'),'journal_sha256':digest(archive/'journal.json'),'proof_sha256':digest(archive/'installed-component-proof.json'),'files_metadata':metadata}
try:
    before=observe();r['before']=before
    command=[CLI,'vm','bind-core-bundle','task8-copy','--library-root',str(VM.parent),'--version',target]
    p=subprocess.run(command,capture_output=True,text=True,timeout=120);r['command']=command;r['exit_code']=p.returncode;r['stdout']=p.stdout;r['stderr']=p.stderr
    assert p.returncode==0
    after=observe();r['after']=after
    assert after['binding']==dict(before['binding'],bundle=target)
    for key in ('receipt_sha256','desired_sha256','journal_sha256','proof_sha256','files_metadata'):assert after[key]==before[key]
    with (E/(label+'-host-binding.json')).open('xb') as artifact:artifact.write((VM/'launchpad.json').read_bytes())
    r['passed']=True
except BaseException as error:r['error']=repr(error);raise
finally:
    output.write(json.dumps(r,indent=2)+'\n');output.close();print(json.dumps(r))
    if not r['passed']:raise RuntimeError('Formal host rebind boundary verification failed')

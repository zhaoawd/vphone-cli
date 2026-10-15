"""Freeze the stopped acceptance VM before an official kernel update or rollback."""
from pathlib import Path
import fcntl,hashlib,json,os,plistlib,stat,subprocess,sys,re
E=Path(__file__).resolve().parent
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
assert len(sys.argv)==2 and re.fullmatch(r'[a-z0-9-]+',sys.argv[1])
label=sys.argv[1];out=E/(label+'-before.json');output=out.open('x')
fd=os.open(VM,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
r={'passed':False,'vm':str(VM),'label':label}
def strict(path,hash_only=False):
    f=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        before=os.fstat(f);assert stat.S_ISREG(before.st_mode)
        h=hashlib.sha256();parts=[]
        with os.fdopen(f,'rb',closefd=False) as stream:
            while b:=stream.read(16<<20):
                h.update(b)
                if not hash_only:parts.append(b)
        after=os.fstat(f);named=path.lstat();keys=('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns')
        assert all(getattr(before,k)==getattr(after,k)==getattr(named,k) for k in keys)
        return {'sha256':h.hexdigest(),'metadata':{k:getattr(after,k) for k in keys}},b''.join(parts)
    finally:os.close(f)
try:
    assert not (VM/'.firmware-transaction').exists() and not (VM/'.firmware-desired-pending.json').exists()
    raw=subprocess.check_output(['/usr/bin/hdiutil','info','-plist'])
    attachments=[i for i in plistlib.loads(raw).get('images',[]) if 'vphone-task8-acceptance-vms' in i.get('image-path','')]
    assert not attachments
    baseline=json.loads((E/'clone.json').read_text())['target_files'];r['files']={}
    assert set(baseline)=={'Disk.img','nvram.bin','SEPStorage','config.plist','AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin'}
    for name,old in baseline.items():
        meta,_=strict(VM/name,True)
        assert meta['metadata']['st_ino']==old['inode'] and meta['metadata']['st_dev']==old['device']
        r['files'][name]=meta
    for key,name in [('binding','launchpad.json'),('desired','.firmware-desired-plan.json'),('receipt','.firmware-component-receipts.json')]:
        meta,data=strict(VM/name)
        r[key]=json.loads(data);r[key+'_sha256']=meta['sha256']
        with (E/(label+'-before-'+key+'.json')).open('xb') as artifact:artifact.write(data)
    r['pending']=False;r['task8_attachments']=attachments;r['passed']=True
except BaseException as error:r['error']=repr(error);raise
finally:
    try:
        observation=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
        r['final_task8_attachments']=[i for i in observation.get('images',[]) if 'vphone-task8-acceptance-vms' in i.get('image-path','')]
        r['final_pending']=(VM/'.firmware-transaction').exists() or (VM/'.firmware-desired-pending.json').exists()
        if r['final_task8_attachments'] or r['final_pending']:r['passed']=False
        if r['passed']:
            for key,name in [('binding','launchpad.json'),('desired','.firmware-desired-plan.json'),('receipt','.firmware-component-receipts.json')]:
                meta,_=strict(VM/name,True)
                assert meta['sha256']==r[key+'_sha256']
    except BaseException as error:r['final_observation_error']=repr(error);r['passed']=False
    os.close(fd);output.write(json.dumps(r,indent=2)+'\n');output.close();print(json.dumps(r))
    if not r['passed']:raise RuntimeError('Stopped VM snapshot failed')

"""Readonly test-copy System mount scoped to the actual two-plan DSC test."""
from pathlib import Path
import os,fcntl,json,subprocess,tempfile,plistlib,stat,hashlib,time
ROOT=Path('/Users/qcz3840/github/vphone-cli');E=Path(__file__).resolve().parent
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy');image=VM/'Disk.img'
out=E/'actual-plan-pair-dsc-v2-mount.json';output=out.open('x')
assert not (E/'actual-plan-pair-dsc-v2.json').exists() and not (E/'actual-plan-pair-dsc-v2.log').exists()
fd=os.open(VM,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
base=Path(tempfile.mkdtemp(prefix='task8-plan-pair-dsc-',dir='/private/tmp'));device=None
r={'passed':False,'commands':[],'vm':str(VM),'scope':'Readonly test-copy System mount and actual EXP two-plan producer/DSC test; no VM boot or source VM mount'}
def run(args):
    p=subprocess.run(args,capture_output=True);r['commands'].append({'command':args,'exit_code':p.returncode,'stderr':p.stderr.decode(errors='replace')});p.check_returncode();return p.stdout
def attached():
    return [i for i in plistlib.loads(run(['/usr/bin/hdiutil','info','-plist'])).get('images',[]) if 'vphone-task8-acceptance-vms' in i.get('image-path','')]
def metadata():
    s=image.lstat();assert stat.S_ISREG(s.st_mode);return {k:getattr(s,k) for k in ('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns')}
try:
    assert not (VM/'.firmware-transaction').exists() and not (VM/'.firmware-desired-pending.json').exists() and not attached()
    r['disk_metadata_before']=metadata()
    a=plistlib.loads(run(['/usr/bin/sudo','-n','/usr/bin/hdiutil','attach','-readonly','-nomount','-nobrowse','-plist',str(image)]))
    disks=[x['dev-entry'] for x in a['system-entities'] if x.get('content-hint')=='GUID_partition_scheme'];assert len(disks)==1;device=disks[0]
    cs=plistlib.loads(run(['/usr/sbin/diskutil','apfs','list','-plist']))['Containers']
    cs=[c for c in cs if [s['DeviceIdentifier'] for s in c['PhysicalStores']]==[device.removeprefix('/dev/')+'s1']];assert len(cs)==1
    vs=[v for v in cs[0]['Volumes'] if v.get('Name')=='System' and v.get('Roles')==['System']];assert len(vs)==1
    volume='/dev/'+vs[0]['DeviceIdentifier'];mount=base/'system';mount.mkdir()
    run(['/usr/bin/sudo','-n','/sbin/mount_apfs','-o','rdonly',volume,str(mount)])
    info=plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',volume]));assert info['WritableVolume'] is False and info['MountPoint']==str(mount) and info['VolumeUUID']==vs[0]['APFSVolumeUUID']
    r['system_info']=info
    env=os.environ.copy();env.update(PYTHONDONTWRITEBYTECODE='1',VPHONE_TEST_ROLLBACK_PRISTINE='/private/tmp/task8-pristine-kernel.im4p',VPHONE_TEST_ROLLBACK_INPUT_SHA256='b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac',VPHONE_TEST_ROLLBACK_DSC_SYSTEM=str(mount),VPHONE_TEST_ROLLBACK_PAIR_OUT=str(E/'actual-plan-pair-dsc-v2.json'),CLANG_MODULE_CACHE_PATH=str(ROOT/'.build/test-module-cache'),SWIFT_MODULECACHE_PATH=str(ROOT/'.build/test-module-cache'))
    cmd=['/usr/bin/swift','test','--disable-sandbox','--scratch-path','/private/tmp/vphone-five-tasks-swift-20261012','--cache-path',str(ROOT/'.build/test-cache'),'--force-resolved-versions','--no-parallel','--filter','actualPublicForceExcGuardPlansProduceDifferentPayloads']
    started=time.monotonic();print(json.dumps({'stage':'readonly System mounted; actual two-plan DSC test starting','volume':volume,'mount':str(mount)}),flush=True)
    with (E/'actual-plan-pair-dsc-v2.log').open('xb') as log:
        test=subprocess.run(cmd,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
    r['test']={'command':cmd,'exit_code':test.returncode,'elapsed_seconds':time.monotonic()-started,'environment':{k:env[k] for k in ('VPHONE_TEST_ROLLBACK_PRISTINE','VPHONE_TEST_ROLLBACK_INPUT_SHA256','VPHONE_TEST_ROLLBACK_DSC_SYSTEM','VPHONE_TEST_ROLLBACK_PAIR_OUT','CLANG_MODULE_CACHE_PATH','SWIFT_MODULECACHE_PATH')}}
    assert test.returncode==0
    pair=json.loads((E/'actual-plan-pair-dsc-v2.json').read_text());r['pair']=pair
    assert pair['inputSHA256']==env['VPHONE_TEST_ROLLBACK_INPUT_SHA256'] and pair['variant']=='exp' and pair['payloadsDiffer'] is True and len(pair['plans'])==2
    assert {p['forceExcGuard'] for p in pair['plans']}=={False,True} and all(p['dsc']=='passed' for p in pair['plans']) and len({p['payloadSHA256'] for p in pair['plans']})==2
    after=plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',volume]));assert after['WritableVolume'] is False and after['MountPoint']==str(mount) and after['VolumeUUID']==info['VolumeUUID']
    r['passed']=True
except BaseException as error:r['error']=repr(error);raise
finally:
    try:
        if device is None:
            candidates=[i for i in attached() if os.path.realpath(i.get('image-path',''))==str(image)]
            if candidates:
                assert len(candidates)==1;disks=[x['dev-entry'] for x in candidates[0]['system-entities'] if x.get('content-hint')=='GUID_partition_scheme'];assert len(disks)==1;device=disks[0]
        if device:run(['/usr/bin/sudo','-n','/usr/bin/hdiutil','detach',device])
        r['remaining_attachments']=attached();r['disk_metadata_after']=metadata()
        assert not r['remaining_attachments'] and r['disk_metadata_after']==r['disk_metadata_before']
        assert not (VM/'.firmware-transaction').exists() and not (VM/'.firmware-desired-pending.json').exists()
        for path in base.iterdir():path.rmdir()
        base.rmdir()
    except BaseException as error:r['cleanup_error']=repr(error);r['passed']=False
    os.close(fd);output.write(json.dumps(r,indent=2)+'\n');output.close();print(json.dumps(r),flush=True)
    if not r['passed']:raise RuntimeError('Actual plan pair/readonly System DSC verification failed')

"""Readonly test-copy System mount scoped to the actual two-plan DSC test."""
from pathlib import Path
import os,fcntl,json,subprocess,tempfile,plistlib,stat,hashlib,time
ROOT=Path('/Users/qcz3840/github/vphone-cli');E=Path(__file__).resolve().parent
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy');image=VM/'Disk.img'
out=E/'dsc-path-diagnostic.json';output=out.open('x')

fd=os.open(VM,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
base=Path(tempfile.mkdtemp(prefix='task8-plan-pair-dsc-',dir='/private/tmp'));device=None
r={'passed':False,'commands':[],'vm':str(VM),'scope':'Readonly System URL path diagnostic; no DSC validation claim or VM boot/source mount'}
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
    diagnostic=Path('/private/tmp/task8-dsc-url-diagnostic.swift')
    diagnostic.write_text("""import Foundation
let system = URL(fileURLWithPath: CommandLine.arguments.last!)
let root = system.appendingPathComponent("System/Cryptexes/OS/System/Library/Caches/com.apple.dyld")
for u in [system, root] + (try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) {
    print(String(data: try JSONSerialization.data(withJSONObject: ["raw":u.path,"standardized":u.standardizedFileURL.path,"resolved":u.resolvingSymlinksInPath().path], options: [.sortedKeys]), encoding:.utf8)!)
}
""")
    r['diagnostic_stdout']=run(['/usr/bin/swift','-module-cache-path',str(ROOT/'.build/test-module-cache'),str(diagnostic),str(mount)]).decode()
    r['filesystem_paths']={str(p):{'realpath':os.path.realpath(p),'is_symlink':p.is_symlink()} for p in [mount,mount/'System/Cryptexes/OS',mount/'System/Cryptexes/OS/System/Library/Caches/com.apple.dyld']}
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
    if not r['passed']:raise RuntimeError('Readonly DSC path diagnostic failed')

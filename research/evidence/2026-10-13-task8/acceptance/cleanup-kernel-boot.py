"""Read-only post-stop checks for the authorized Task 8 VM and source metadata."""
from pathlib import Path
import json,subprocess,plistlib,os,fcntl,hashlib,sys,re,stat
E=Path(__file__).resolve().parent;VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy');SOURCE=Path('/Users/qcz3840/github/vphone-cli/vm-new')
assert len(sys.argv)==2 and re.fullmatch(r'[a-z0-9-]+',sys.argv[1])
label=sys.argv[1];output=(E/(label+'-post-boot-cleanup.json')).open('x');r={'passed':False,'label':label};fds=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def meta(p):
    s=p.lstat();assert stat.S_ISREG(s.st_mode);return {'device':s.st_dev,'inode':s.st_ino,'size':s.st_size,'mtime_ns':s.st_mtime_ns,'ctime_ns':s.st_ctime_ns}
try:
    expected=json.loads((E/(label+'-boot-expectations.json')).read_text());boot=json.loads((E/(label+'-boot-watch.json')).read_text());assert boot['passed'] is True and boot['expected']==expected
    for directory in (VM,SOURCE):
        fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);fds.append(fd)
    old=json.loads((E/'clone.json').read_text());names={'Disk.img','nvram.bin','SEPStorage','config.plist','AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin'};assert set(old['source_before'])==set(old['target_files'])==names
    source={n:meta(SOURCE/n) for n in sorted(names)};target={n:meta(VM/n) for n in sorted(names)}
    assert all(all(source[n][k]==old['source_before'][n][k] for k in source[n]) for n in names)
    assert all(all(target[n][k]==old['target_files'][n][k] for k in ('device','inode','size')) for n in names)
    baseline=json.loads((E/'baseline-digests.json').read_text())[str(VM)]
    static_hashes={n:sha(VM/n) for n in ('config.plist','AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin')}
    assert all(static_hashes[n]==baseline[n]['sha256'] for n in static_hashes)
    ps=subprocess.run(['/bin/ps','-axo','pid=,ppid=,stat=,command='],capture_output=True,text=True,check=True)
    processes=[]
    for line in ps.stdout.splitlines():
        parts=line.strip().split(None,3)
        if len(parts)!=4:continue
        command=parts[3]
        if ('/vphone-vm ' in command and '--config '+str(VM/'config.plist')+' ' in command) or str(E/'scoped-amfi-v4') in command:processes.append(line)
    assert not processes
    attached=[i for i in plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist'])).get('images',[]) if 'vphone-task8-acceptance-vms' in i.get('image-path','')]
    assert not attached and not (VM/'.firmware-transaction').exists() and not (VM/'.firmware-desired-pending.json').exists()
    assert sha(VM/'launchpad.json')==expected['binding_sha256'] and json.loads((VM/'launchpad.json').read_text())==expected['binding']
    assert sha(VM/'.firmware-component-receipts.json')==expected['receipt_sha256']
    if 'desired_sha256' in expected:assert sha(VM/'.firmware-desired-plan.json')==expected['desired_sha256']
    r.update(source_metadata=source,source_metadata_unchanged=True,source_scope='six device/inode/size/mtime_ns/ctime_ns only; no new source content hash',test_metadata=target,test_file_identities_unchanged=True,static_test_file_sha256=static_hashes,task8_processes=processes,task8_attachments=attached,pending_transaction=False,desired_pending=False,binding_unchanged=True,receipt_unchanged=True,passed=True)
except BaseException as error:r['error']=repr(error);raise
finally:
    for fd in fds:os.close(fd)
    output.write(json.dumps(r,indent=2)+'\n');output.close();print(json.dumps({'passed':r['passed'],'label':label,'evidence':str(E/(label+'-post-boot-cleanup.json'))}))
    if not r['passed']:raise RuntimeError('Post-boot cleanup verification failed')

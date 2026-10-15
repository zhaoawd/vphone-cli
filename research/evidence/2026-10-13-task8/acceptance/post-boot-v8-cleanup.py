from pathlib import Path
import json,subprocess,plistlib,os,fcntl,hashlib,datetime
E=Path(__file__).resolve().parent
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
source=Path('/Users/qcz3840/github/vphone-cli/vm-new')
out=E/'post-boot-v8-cleanup.json'
assert not out.exists()
fds=[]
for directory in [VM,source]:
    fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);fds.append(fd)
def sig(p):
    s=p.stat();return {'device':s.st_dev,'inode':s.st_ino,'size':s.st_size,'mtime_ns':s.st_mtime_ns,'ctime_ns':s.st_ctime_ns}
old=json.loads((E/'clone.json').read_text())['source_before']
current={n:sig(source/n) for n in old}
source_same=all(all(current[n][k]==old[n][k] for k in current[n]) for n in old)
ps=subprocess.run(['/bin/ps','-axo','pid=,ppid=,stat=,command='],capture_output=True,text=True,check=True)
owned=[line for line in ps.stdout.splitlines() if ('/vphone-vm ' in line and str(VM) in line) or 'scoped-amfi-v4' in line or line.split()[0] in {'22914','89299','89316'}]
raw=subprocess.check_output(['/usr/bin/hdiutil','info','-plist'])
(E/'post-boot-v8-attachments.plist').write_bytes(raw)
attachments=[i for i in plistlib.loads(raw).get('images',[]) if 'vphone-task8-acceptance-vms' in i.get('image-path','')]
binding=(VM/'launchpad.json').read_bytes()
receipt=(VM/'.firmware-component-receipts.json').read_bytes()
record={'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_metadata':current,'source_metadata_unchanged':source_same,'source_scope':'device/inode/size/mtime_ns/ctime_ns only; no new source content hash','test_metadata':{n:sig(VM/n) for n in old},'owned_processes':owned,'task8_attachments':attachments,'pending_transaction':(VM/'.firmware-transaction').exists(),'binding':json.loads(binding),'binding_unchanged_since_boot':binding==(E/'binding-before-boot-v4-kernel-v8.json').read_bytes(),'receipt_sha256':hashlib.sha256(receipt).hexdigest(),'receipt_unchanged_since_host_rebind':hashlib.sha256(receipt).hexdigest()=='266ba0ad4589044c4f736ed2911267db03c22658c8f756fab453bb5e6b855cfb','temporary_amfi_driver_started_this_run':False}
record['passed']=source_same and not owned and not attachments and not record['pending_transaction'] and record['binding_unchanged_since_boot'] and record['receipt_unchanged_since_host_rebind']
out.write_text(json.dumps(record,indent=2)+'\n')
for fd in fds:os.close(fd)
print(json.dumps(record))
assert record['passed']

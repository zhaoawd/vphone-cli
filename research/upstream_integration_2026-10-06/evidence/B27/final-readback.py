import hashlib,json,subprocess
from pathlib import Path
root=Path('/private/tmp/vphone-b27');vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');result={}
args=['/bin/ps','-axo','pid,ppid,stat,command'];p=subprocess.run(args,capture_output=True,text=True,check=True);lines=[line for line in p.stdout.splitlines() if any(x in line for x in ['/private/tmp/vphone-b26-runtime/scoped.py','/usr/libexec/amfid','LLDB.framework/Resources/debugserver','Contents/MacOS/vphone-vm'])];result['processes']=lines
assert not any('scoped.py' in x or 'debugserver' in x for x in lines)
assert not any('81949 ' in x or '84568 ' in x for x in lines)
amfid=[x.split(None,3) for x in lines if '/usr/libexec/amfid' in x];assert all('T' not in x[2] and x[1]=='1' for x in amfid)
assert any(x.lstrip().startswith('35668 ') for x in lines)
p=subprocess.run(['/usr/sbin/lsof','-nP',str(vm/'Disk.img')],capture_output=True,text=True);result['disk_lsof']={'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr};assert p.returncode==1 and not p.stdout
before=json.loads((root/'vm-before.json').read_text());after={}
for name,row in before.items():
 p=vm/name;after[name]={'exists':p.exists()}
 if p.is_file():after[name].update(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
result['files_after']=after;result['configuration_preserved']=after['config.plist']==before['config.plist'];result['host_guest_payload_preserved']=after['.vphoned.signed']==before['.vphoned.signed'];assert result['configuration_preserved'] and result['host_guest_payload_preserved']
result['amfi_configuration_files']={str(p):{'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in Path('/private/tmp/vphone-b26-runtime/config').iterdir() if p.is_file()};assert all(x['bytes']==0 for x in result['amfi_configuration_files'].values())
p=subprocess.run(['/bin/launchctl','print','system/com.apple.MobileFileIntegrity'],capture_output=True,text=True);(root/'amfid-final-launchctl.txt').write_text(p.stdout);result['amfid_launchctl_exit']=p.returncode;assert p.returncode==0
result['disk_space']=subprocess.run(['/bin/df','-k',str(vm)],capture_output=True,text=True).stdout
(root/'final-readback.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

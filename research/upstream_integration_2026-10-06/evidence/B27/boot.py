import hashlib,json,subprocess,time
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new'); root=Path('/private/tmp/vphone-b27')
binary=Path('/private/tmp/vphone-b26-runtime/vphone-cli.app/Contents/MacOS/vphone-vm')
assert hashlib.sha256(binary.read_bytes()).hexdigest()=='c8e8be423f47c2bc85a7bca5715c306a49cbacba1442a5882416493660a5f8ff'
files={}
for name in ['config.plist','.vphoned.signed','restore-info.json','.vphone-runtime.json','launchpad.json']:
 p=vm/name
 files[name]={'exists':p.exists()}
 if p.is_file(): files[name].update(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
assert files['.vphoned.signed']['sha256']=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
(root/'vm-before.json').write_text(json.dumps(files,indent=2)+'\n')
args=[str(binary),'--config',str(vm/'config.plist'),'--variant','exp','--headless','--vphoned-bin',str(vm/'.vphoned.signed'),'--no-vphoned-update']
start=time.monotonic()
with (root/'vm-boot.log').open('wb') as log:
 p=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT)
 (root/'vm-process.json').write_text(json.dumps({'pid':p.pid,'arguments':args,'start_time':time.time()},indent=2)+'\n')
 print('VM_STARTED pid='+str(p.pid),flush=True)
 rc=p.wait()
(root/'vm-exit.json').write_text(json.dumps({'pid':p.pid,'exit':rc,'seconds':time.monotonic()-start},indent=2)+'\n')
print('VM_EXIT '+str(rc),flush=True)

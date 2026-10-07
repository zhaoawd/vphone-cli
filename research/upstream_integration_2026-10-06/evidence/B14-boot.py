import hashlib,json,os,subprocess,sys,time
from pathlib import Path
binary=Path(sys.argv[1]).resolve(strict=True)
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new')
checkpoint=json.loads(Path('/private/tmp/vphone-b14-checkpoint.json').read_text())
assert checkpoint['status']=='verified'
assert checkpoint['source']==str(vm)
assert (vm/'config.plist').is_file() and (vm/'.vphoned.signed').is_file()
for n in ['config.plist','.vphoned.signed']:
 assert hashlib.sha256((vm/n).read_bytes()).hexdigest()==checkpoint['files'][n]['sha256']
assert os.statvfs(vm).f_bavail*os.statvfs(vm).f_frsize>=12*1024**3
files=[str(vm/n) for n in checkpoint['files']]
r=subprocess.run(['/usr/sbin/lsof','-t','--',*files],capture_output=True,text=True)
assert r.returncode==1 and not r.stdout.strip(),'VM regular files are open'
args=[str(binary),'--config',str(vm/'config.plist'),'--variant','exp','--vphoned-bin',str(vm/'.vphoned.signed'),'--no-vphoned-update','--unlock-at-startup']
env=dict(os.environ)
if sys.argv[2:]==['--api']:
 import secrets
 token=secrets.token_urlsafe(32)
 path=Path('/private/tmp/vphone-b14-restart-token')
 fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:f.write(token)
 env['VPHONE_API_TOKEN']=token
 args+=['--api-listen','127.0.0.1:0']
elif sys.argv[2:]:raise RuntimeError('unknown option')
log=Path('/private/tmp/vphone-b14-restart-boot.log')
with log.open('xb') as output:
 process=subprocess.Popen(args,cwd=vm,stdout=output,stderr=subprocess.STDOUT,env=env)
 Path('/private/tmp/vphone-b14-restart-boot-process.json').write_text(json.dumps({'pid':process.pid,'binary':str(binary),'arguments':args,'started_at':time.time()},indent=2)+'\n')
 print('VM_PID='+str(process.pid),flush=True)
 code=process.wait()
 print('VM_EXIT='+str(code),flush=True)
 raise SystemExit(code)

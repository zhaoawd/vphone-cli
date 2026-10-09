import hashlib,json,os,secrets,subprocess,time
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');vm=Path('/Users/qcz3840/github/vphone-cli/vm.backups/b21-restored-vm-new-20261009');binding=json.loads((vm/'launchpad.json').read_text());local=json.loads(Path('/private/tmp/vphone-b22-local-core-bundle.json').read_text());assert binding['bundle']==local['version'];store=Path('/Library/Application Support/vphone-launchpad/Bundles')/binding['bundle']/'VPhone.bundle';binary=store/'Contents/MacOS/vphone-vm';assert hashlib.sha256(binary.read_bytes()).hexdigest()=='1d21a984f4621fcc291ebc6d48bc572ec1c316752183dbcf40469a7778a4eb80'
token=secrets.token_urlsafe(32);path=Path('/private/tmp/vphone-b22-bound-token');fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f:f.write(token)
args=[str(r/'.build/vphone-cli.app/Contents/MacOS/vphone-cli'),'vm','launch','--library-root',str(vm.parent),vm.name,'--variant','exp','--api-listen','127.0.0.1:0'];env={**os.environ,'VPHONE_API_TOKEN':token}
with Path('/private/tmp/vphone-b22-bound-boot.log').open('xb') as output:
 p=subprocess.Popen(args,cwd=vm,stdout=output,stderr=subprocess.STDOUT,env=env)
 Path('/private/tmp/vphone-b22-bound-process.json').write_text(json.dumps({'wrapper_pid':p.pid,'arguments':args,'selected_version':binding['bundle'],'selected_VM':str(binary),'selected_VM_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'binding_sha256':hashlib.sha256((vm/'launchpad.json').read_bytes()).hexdigest(),'started_at':time.time()},indent=2)+'\n');print('WRAPPER_PID='+str(p.pid),flush=True)
 code=p.wait();print('BOUND_VM_EXIT='+str(code),flush=True);raise SystemExit(code)

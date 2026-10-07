import hashlib,json,os,plistlib,secrets,subprocess,time
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');binary=r/'.build/acceptance/B13/candidate.app/Contents/MacOS/vphone-vm';checkpoint=Path('/Users/qcz3840/github/vphone-cli/vm.backups/b14-vm-new-stopped-20261008')
old=plistlib.loads((checkpoint/'config.plist').read_bytes());current=plistlib.loads((vm/'config.plist').read_bytes());assert current.pop('unlockAtStartup') is True;assert current==old
assert hashlib.sha256(binary.read_bytes()).hexdigest()=='db62e750f65208a662708c155cf1ac3dec2aac68d2de14684fcef6bf5293a548'
assert hashlib.sha256((vm/'.vphoned.signed').read_bytes()).hexdigest()=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
assert os.statvfs(vm).f_bavail*os.statvfs(vm).f_frsize>=12*1024**3
files=[str(p) for p in vm.rglob('*') if p.is_file() and not p.is_symlink()];holders=subprocess.run(['/usr/sbin/lsof','-nP','-t','--',*files],capture_output=True,text=True,timeout=15);assert holders.returncode==1 and not holders.stdout
cli=r/'.build/acceptance/B13/candidate.app/Contents/MacOS/vphone-cli';deny=subprocess.run([str(cli),'vm','launch','vm-new','--library-root',str(vm.parent),'--variant','exp'],capture_output=True,text=True,timeout=15);assert deny.returncode==64 and 'supply --api-listen' in deny.stderr;Path('/private/tmp/vphone-b14-launch-without-api.json').write_text(json.dumps({'command':deny.args,'returncode':deny.returncode,'stdout':deny.stdout,'stderr':deny.stderr},indent=2)+'\n')
token=secrets.token_urlsafe(32);fd=os.open('/private/tmp/vphone-b14-second-token',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f:f.write(token)
args=[str(binary),'--config',str(vm/'config.plist'),'--variant','exp','--vphoned-bin',str(vm/'.vphoned.signed'),'--no-vphoned-update','--api-listen','127.0.0.1:0'];env=dict(os.environ);env['VPHONE_API_TOKEN']=token
with Path('/private/tmp/vphone-b14-second-boot.log').open('xb') as output:
 p=subprocess.Popen(args,cwd=vm,env=env,stdout=output,stderr=subprocess.STDOUT);Path('/private/tmp/vphone-b14-second-boot-process.json').write_text(json.dumps({'pid':p.pid,'args':args,'source_head':'55fd8ef5','unlock_flag_provided':False,'stored_unlock_enabled':True,'amfid_helper_active':False,'started_at':time.time()},indent=2)+'\n');print('VM_PID='+str(p.pid),flush=True);code=p.wait();print('VM_EXIT='+str(code),flush=True);raise SystemExit(code)

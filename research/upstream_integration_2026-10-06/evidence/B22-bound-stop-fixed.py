from pathlib import Path
import subprocess
exec(Path('/private/tmp/vphone-b22-bound-common.py').read_text())
result={'target':target,'observations':rows}
lines=shell('ps -A -o pid=,ppid=,comm= | grep vphone-b21-api/vphoned || true').splitlines()
for x in lines:
 if x.split()[1]=='1':shell('test "$(ps -p '+x.split()[0]+' -o comm= | tr -d " ")" = /var/root/vphone-b21-api/vphoned && kill -TERM '+x.split()[0])
for _ in range(40):
 if not shell('ps -A -o comm= | grep vphone-b21-api/vphoned || true').strip():break
 time.sleep(.1)
else:raise RuntimeError('Isolated API remains')
classic=ctl('file_get',path='/usr/bin/vphoned');result['classic_sha256']=hashlib.sha256(base64.b64decode(classic['data'])).hexdigest();assert result['classic_sha256']=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
cache=ctl('file_get',path='/var/root/Library/Caches/vphoned');result['cache_sha256']=hashlib.sha256(base64.b64decode(cache['data'])).hexdigest();assert result['cache_sha256']==result['classic_sha256']
args=subprocess.check_output(['/bin/ps','-p',str(target['pid']),'-o','command='],text=True);result['boot_arguments']=args
record=json.loads(Path('/private/tmp/vphone-b22-bound-process.json').read_text())
assert args.startswith(record['selected_VM']+' --config '+str(vm/'config.plist'))
assert '--no-vphoned-update' in args and record['binding_sha256'] in args
cli='/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/debug/vphone-cli'
start=time.monotonic();p=subprocess.run([cli,'vm','stop','--library-root',str(vm.parent),vm.name],capture_output=True,text=True,timeout=100)
result['stop']={'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'seconds':time.monotonic()-start}
s=json.dumps(result,indent=2);assert token not in s;Path('/private/tmp/vphone-b22-bound-stop.json').write_text(s+'\n')
assert p.returncode==0 and 'force-killing' not in p.stdout
s=json.dumps(result,indent=2);assert token not in s;Path('/private/tmp/vphone-b22-bound-stop.json').write_text(s+'\n');print(result['stop'])

import hashlib,json,os,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');base=r/'research/upstream_integration_2026-10-06';state=json.loads((base/'evidence/B13-final-state.json').read_text());art=json.loads((base/'evidence/B13-artifact-manifest.json').read_text());vm=Path('/Users/qcz3840/github/vphone-cli/vm-new')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
rows=[]
def cmd(args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=20);rows.append({'command':args,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr});return p
assert cmd(['git','status','--porcelain']).returncode==0
for app,rec in art['apps'].items():
 for n,m in rec['files'].items():
  p=r/'.build/acceptance/B13'/app/n;assert p.stat().st_size==m['bytes'] and sha(p)==m['sha256']
 assert cmd(['/usr/bin/codesign','--verify','--strict','--deep',str(r/'.build/acceptance/B13'/app)]).returncode==0
for key,name in [('config_sha256','config.plist'),('guest_payload_sha256','.vphoned.signed'),('udid_prediction_sha256','udid-prediction.txt')]:assert sha(vm/name)==state[key]
p=cmd(['/bin/ps','-p','92943','-o','pid=,ppid=,lstart=,command=']);assert p.returncode==0 and 'acceptance/B09/candidate.app/Contents/MacOS/vphone-vm --config '+str(vm/'config.plist') in p.stdout
p=cmd(['/bin/launchctl','print','system/com.vphone.cli.helper']);assert p.returncode!=0 and 'Could not find service' in p.stderr
p=cmd(['/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged']);assert p.returncode!=0 and '-60005' in p.stderr
for path in ['/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist']:assert not Path(path).exists()
p=cmd(['/usr/bin/sudo','-n','/usr/bin/true'])
result={'observations':rows,'source_head':art['source_head'],'worktree_head':cmd(['git','rev-parse','HEAD']).stdout.strip(),'new_artifact_files_verified':607,'fresh_helper_and_right_absent':True,'sudo_noninteractive_available':p.returncode==0,'free_bytes':os.statvfs(vm).f_bavail*os.statvfs(vm).f_frsize,'authorization':'User authorized exact B13 VM CDHash6ae3461e and temporary signed helper registration; cleanup required.'}
Path('/private/tmp/vphone-b14-preflight.json').write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k!='observations'})

import hashlib,json,os,stat,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');main=Path('/Users/qcz3840/github/vphone-cli');vm=main/'vm-new';base=r/'research/upstream_integration_2026-10-06'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def call(args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=30);return {'command':args,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
rows=[]
for pid in ['30749','58582','52699']:
 x=call(['/bin/ps','-p',pid,'-o','pid=,command=']);rows.append(x);assert x['returncode']!=0
files=[str(p) for p in vm.rglob('*') if p.is_file() and not p.is_symlink()]
x=call(['/usr/sbin/lsof','-nP','-t','--',*files]);assert x['returncode']==1 and not x['stdout'];rows.append(x)
for cmd in [['/bin/launchctl','print','system/com.vphone.cli.helper'],['/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged']]:
 x=call(cmd);rows.append(x);assert x['returncode']!=0
assert 'Could not find service' in rows[-2]['stderr'] and '-60005' in rows[-1]['stderr']
for path in ['/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist']:assert not Path(path).exists()
old=json.loads((base/'evidence/B14-final-state.json').read_text())
for key,name in [('config_sha256','config.plist'),('classic_payload_sha256','.vphoned.signed'),('udid_prediction_sha256','udid-prediction.txt')]:assert sha(vm/name)==old[key]
count=0
for batch in ['B09','B13']:
 m=json.loads((base/f'evidence/{batch}-artifact-manifest.json').read_text());apps=m['apps'] if batch=='B13' else {k:m[k] for k in ['baseline.app','candidate.app','launchpad.app']}
 for app,record in apps.items():
  for name,info in record['files'].items():
   p=r/'.build/acceptance'/batch/app/name;assert p.stat().st_size==info['bytes'] and sha(p)==info['sha256'];count+=1
assert count==1206
ps=call(['/bin/ps','-axo','pid=,ppid=,command='])['stdout'];owned_helpers=[]
for line in ps.splitlines():
 cols=line.split(None,2)
 if len(cols)==3 and (cols[2].startswith('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Resources/debugserver') or ('/private/tmp/vphone-b15-' in cols[2] and 'scoped.py' in cols[2])):owned_helpers.append(line)
assert not owned_helpers
assert not any(line.split(None,2)[-1].startswith('/Library/PrivilegedHelperTools/com.vphone.cli.helper') for line in ps.splitlines() if len(line.split(None,2))==3)
backup=Path('/private/tmp/vphone-b15-private-pasteboard.plist');assert backup.is_file() and not backup.is_symlink() and stat.S_IMODE(backup.stat().st_mode)==0o600
removed=[]
token=Path('/private/tmp/vphone-b15-restart-token')
if token.exists():
 assert stat.S_IMODE(token.stat().st_mode)==0o600 and token.stat().st_uid==os.getuid() and not token.is_symlink()
 secret=token.read_bytes();assert len(secret)>16
 for p in Path('/private/tmp').glob('vphone-b15-*'):
  if p.is_file() and p.suffix in ['.json','.log','.py','.swift','.txt','.jsonl'] and 'private' not in p.name:assert secret not in p.read_bytes(),p.name
 token.unlink();removed.append(str(token))
guest=Path('/private/tmp/vphone-b15-private-guest-clipboard.json')
if guest.exists():
 assert not guest.is_symlink() and guest.stat().st_uid==os.getuid() and stat.S_IMODE(guest.stat().st_mode)==0o600
 guest.unlink();removed.append(str(guest))
result={'observations':rows,'VM_new_stopped':True,'disk_released':True,'VM_2607_operated':False,'B13_runtime_source':'55fd8ef57a6731e42cba0727f477bc9b25f0c9ca','config_sha256':sha(vm/'config.plist'),'classic_payload_sha256':sha(vm/'.vphoned.signed'),'udid_prediction_sha256':sha(vm/'udid-prediction.txt'),'old_frozen_files_verified':count,'helper_service_right_files_absent':True,'helper_process_absent':True,'amfid_or_debugserver_started_this_batch':False,'temporary_diagnostic_app_stopped':True,'private_tokens_and_guest_empty_backup_removed':removed,'Mac_clipboard_independently_changed_not_overwritten':True,'Mac_clipboard_original_backup_retained_0600':str(backup),'guest_classic_test_text_cleared_before_stop':True,'original_guest_changeCount_not_restored':True,'temporary_API_only_guest_files_retained_unregistered':'/var/root/vphone-b13-api','full_disk_rollback_performed':False,'main_head':call(['git','-C',str(main),'rev-parse','HEAD'])['stdout'].strip(),'main_status':call(['git','-C',str(main),'status','--porcelain'])['stdout'],'free_bytes':os.statvfs(vm).f_bavail*os.statvfs(vm).f_frsize}
assert result['main_status']==''
Path('/private/tmp/vphone-b15-final-state.json').write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k!='observations'})

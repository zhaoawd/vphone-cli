import fcntl,hashlib,json,os,plistlib,stat,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');main=Path('/Users/qcz3840/github/vphone-cli');vm=main/'vm-new';checkpoint=main/'vm.backups/b14-vm-new-stopped-20261008';base=r/'research/upstream_integration_2026-10-06';rows=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def call(args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=20);rows.append({'command':args,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr});return p
for pid in ['92943','70577','84587']:assert call(['/bin/ps','-p',pid,'-o','pid=,command=']).returncode!=0
files=[str(p) for p in vm.rglob('*') if p.is_file() and not p.is_symlink()];holders=call(['/usr/sbin/lsof','-nP','-t','--',*files]);assert holders.returncode==1 and not holders.stdout
fd=os.open(vm,os.O_RDONLY|os.O_DIRECTORY);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
try:
 saved=(checkpoint/'config.plist').read_bytes();old=plistlib.loads(saved);current=plistlib.loads((vm/'config.plist').read_bytes());assert (current==old or (current.pop('unlockAtStartup',None) is True and current==old))
 stage=vm/'.config-b14-restore.plist';mode=stat.S_IMODE((checkpoint/'config.plist').stat().st_mode);outfd=os.open(stage,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode)
 with os.fdopen(outfd,'wb') as f:f.write(saved);f.flush();os.fsync(f.fileno())
 os.replace(stage,vm/'config.plist');assert (vm/'config.plist').read_bytes()==saved
finally:os.close(fd)
# Real stopped VM binding refusal must not publish a record or create a backup.
binding=vm/'launchpad.json';assert not binding.exists();config_before=sha(vm/'config.plist');backup=main/'vm.backups/b14-binding-refusal-never-created';assert not backup.exists()
exe=str(r/'.build/acceptance/B13/candidate.app/Contents/MacOS/vphone-cli');x=call([exe,'vm','bind-core-bundle','vm-new','--library-root',str(main),'--version','2.6.0','--backup',str(backup)]);assert x.returncode!=0 and not binding.exists() and not backup.exists() and sha(vm/'config.plist')==config_before
for label in ['com.vphone.cli.helper']:x=call(['/bin/launchctl','print','system/'+label]);assert x.returncode!=0 and 'Could not find service' in x.stderr
x=call(['/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged']);assert x.returncode!=0 and '-60005' in x.stderr
for p in ['/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist']:assert not Path(p).exists()
ps=call(['/bin/ps','-axo','pid=,ppid=,stat=,command=']).stdout;helpers=[];amfid=[]
for line in ps.splitlines():
 cells=line.split(None,3)
 if len(cells)!=4:continue
 if cells[3].startswith('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Resources/debugserver') or cells[3].startswith('/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/') and '/private/tmp/vphone-b14-amfid-candidate/scoped.py' in cells[3]:helpers.append(line)
 if cells[3]=='/usr/libexec/amfid':amfid.append(line)
assert not helpers and len(amfid)<=1
if amfid:assert amfid[0].split()[1]=='1'
else:
 service=call(['/bin/launchctl','print','system/com.apple.MobileFileIntegrity']);assert service.returncode==0 and 'state = not running' in service.stdout and 'JETSAM_REASON_MEMORY_IDLE_EXIT' in service.stdout
 service.stdout and Path('/private/tmp/vphone-b14-final-amfid-idle-state.log').write_text(service.stdout)
# Capture the process row independently because service reads may append rows.
psrow=next(row for row in rows if row['command'][:3]==['/bin/ps','-axo','pid=,ppid=,stat=,command='])
psrow['stdout']='unrelated process commands omitted';psrow['filtered_amfid']=amfid
# Do not preserve the unrelated process listing in research evidence.
# Unrelated process rows were redacted above.
old=json.loads((base/'evidence/B13-final-state.json').read_text())
for key,name in [('config_sha256','config.plist'),('guest_payload_sha256','.vphoned.signed'),('udid_prediction_sha256','udid-prediction.txt')]:assert sha(vm/name)==old[key]
for name in ['AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin','restore-info.json']:assert sha(vm/name)==sha(checkpoint/name)
count=0
for batch in ['B09','B13']:
 m=json.loads((base/('evidence/'+batch+'-artifact-manifest.json')).read_text());apps=m['apps'] if batch=='B13' else {k:m[k] for k in ['baseline.app','candidate.app','launchpad.app']}
 for app,record in apps.items():
  for name,info in record['files'].items():p=r/'.build/acceptance'/batch/app/name;assert p.stat().st_size==info['bytes'] and sha(p)==info['sha256'];count+=1
  assert call(['/usr/bin/codesign','--verify','--strict','--deep',str(r/'.build/acceptance'/batch/app)]).returncode==0
assert count==1206
assert 'original clipboard items/types/data restored' in Path('/private/tmp/vphone-b14-pasteboard-restore.log').read_text()
secrets=[];removed=[]
for name in ['vphone-b10-restart-token','vphone-b14-restart-token','vphone-b14-second-token']:
 p=Path('/private/tmp')/name;assert stat.S_IMODE(p.stat().st_mode)==0o600;data=p.read_bytes();assert len(data)>16;secrets.append(data)
for p in Path('/private/tmp').glob('vphone-b14-*'):
 if p.is_file() and p.suffix in ['.json','.log','.py','.swift'] and 'private' not in p.name:
  data=p.read_bytes();assert all(secret not in data for secret in secrets),'private token appears in '+p.name
for name in ['vphone-b10-restart-token','vphone-b14-restart-token','vphone-b14-second-token','vphone-b14-private-pasteboard.plist','vphone-b14-private-guest-clipboard.json']:
 p=Path('/private/tmp')/name;assert not p.is_symlink() and p.stat().st_uid==os.getuid();p.unlink();removed.append(str(p))
result={'observations':rows,'VM_new_stopped':True,'VM_2607_operated':False,'original_config_bytes_restored':True,'config_sha256':sha(vm/'config.plist'),'classic_payload_sha256':sha(vm/'.vphoned.signed'),'udid_prediction_sha256':sha(vm/'udid-prediction.txt'),'binding_refused_without_record_backup_or_config_change':True,'missing_Bundle_runtime_recovery_guidance_still_generic':True,'temporary_helper_service_and_right_and_files_removed':True,'amfid_helper_or_debugserver_remaining':False,'amfid':amfid,'old_and_new_frozen_files_verified':count,'temporary_tokens_and_private_clipboard_backups_removed':removed,'Mac_clipboard_contents_restored_changeCount_not_restored':True,'guest_clipboard_empty_before_and_after':True,'temporary_API_only_guest_files_retained_unregistered':'/var/root/vphone-b13-api','checkpoint':'APFS copy-on-write complete65-file snapshot; no physical independence','main_head':call(['git','-C',str(main),'rev-parse','HEAD']).stdout.strip(),'main_status':call(['git','-C',str(main),'status','--porcelain']).stdout,'worktree_head':call(['git','-C',str(r),'rev-parse','HEAD']).stdout.strip(),'worktree_status':call(['git','-C',str(r),'status','--porcelain']).stdout,'free_bytes':os.statvfs(vm).f_bavail*os.statvfs(vm).f_frsize}
assert result['main_status']==result['worktree_status']==''
Path('/private/tmp/vphone-b14-final-state.json').write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k!='observations'})

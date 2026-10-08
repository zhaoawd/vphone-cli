import fcntl,hashlib,json,os,plistlib,shutil,stat,subprocess,time
from pathlib import Path
assert os.geteuid()==0
pre=json.loads(Path('/private/tmp/vphone-b20-helper-preflight.json').read_text());assert pre['fresh_helper_and_right_absent'] and pre['root_store_absent']
result=Path('/private/tmp/vphone-b20-helper-install-retry.json');out=Path('/private/tmp/vphone-b20-finalization.json');assert not out.exists()
client=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/acceptance/B15/helper-client.app/Contents/MacOS/vphone-cli');uid=client.stat().st_uid
root=Path('/Library/Application Support/vphone-launchpad/Bundles');binary=Path('/Library/PrivilegedHelperTools/com.vphone.cli.helper');plist=Path('/Library/LaunchDaemons/com.vphone.cli.helper.plist');right='com.vphone.cli.helper.privileged';expected=pre['exact_helper_SHA256'];rows=[]
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for c in iter(lambda:f.read(1048576),b''):h.update(c)
 return h.hexdigest()
def call(a,timeout=40):
 p=subprocess.run(a,capture_output=True,text=True,timeout=timeout);rows.append({'command':a,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr});return p
j={'observations':rows,'success_install_accepted':False,'cleanup_complete':False}
try:
 deadline=time.monotonic()+1000
 while not result.exists() and time.monotonic()<deadline:time.sleep(1)
 assert result.exists(),'No final install result; preserve state for inspection'
 install=json.loads(result.read_text());j['install_result']=install
 if install.get('returncode')==0:
  receipt=json.loads(install['stdout']);assert receipt['version']=='2.6.1' and receipt['sha256']==pre['archive_sha256']
  assert install['closed_after_return'] and install['mode']=='0o600'
  assert install['log_text']=='Installing Core Bundle 2.6.1\nCore Bundle operation completed\n'
  log='/private/tmp/vphone-b20-helper-verify-output.log'
  p=call([str(client),'helper','verify-bundle','--version','2.6.1','--log-file',log]);assert p.returncode==0,p.stderr
  verified=json.loads(p.stdout);assert verified==receipt
  data=Path(log).read_bytes();assert data==b'Verifying Core Bundle 2.6.1\nCore Bundle operation completed\n'
  holders=call(['/usr/sbin/lsof','-t','--',log]);assert holders.returncode==1 and not holders.stdout
  j['success_install_accepted']=True;j['verified_receipt']=verified;j['verify_log_bytes']=len(data);j['verify_log_mode']=oct(stat.S_IMODE(Path(log).stat().st_mode));os.chown(log,uid,-1)
 else:
  assert not root.exists() and not Path('/private/tmp/vphone-b20-helper-install-retry-output.log').exists(),'Uncertain failed install side effects; preserve state'
  j['authentication_not_completed']=True
 # Only remove the exact service installed after the recorded absent baseline.
 for p in [binary,plist]:
  s=p.lstat();assert stat.S_ISREG(s.st_mode) and s.st_uid==0 and not s.st_mode&0o022
 assert sha(binary)==expected
 pl=plistlib.loads(plist.read_bytes());assert pl['Label']=='com.vphone.cli.helper' and pl['MachServices']['com.vphone.cli.helper'] is True
 assert pl.get('Program')==str(binary) or pl.get('ProgramArguments',[None])[0]==str(binary)
 a=call(['/usr/bin/security','authorizationdb','read',right]);assert a.returncode==0;rule=plistlib.loads(a.stdout.encode());assert rule['class']=='user' and rule['group']=='admin' and rule['authenticate-user'] and not rule['allow-root'] and not rule['shared']
 if j['success_install_accepted']:
  assert not Path('/Users/qcz3840/github/vphone-cli/vm-new/launchpad.json').exists()
  inventory={str(p.relative_to(root/'2.6.1')):{'bytes':p.stat().st_size,'sha256':sha(p),'uid':p.stat().st_uid,'mode':oct(stat.S_IMODE(p.stat().st_mode))} for p in (root/'2.6.1').rglob('*') if p.is_file()}
  j['installed_inventory']=inventory
  with (root/'.store.lock').open('rb') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
   assert set(p.name for p in root.iterdir())=={'2.6.1','.store.lock'}
   # The signed bundle and its receipt were verified through the real helper above.
   shutil.rmtree(root/'2.6.1');(root/'.store.lock').unlink();root.rmdir()
   if not list(root.parent.iterdir()):root.parent.rmdir()
 a=call(['/bin/launchctl','bootout','system',str(plist)]);assert a.returncode==0
 a=call(['/usr/bin/security','authorizationdb','remove',right]);assert a.returncode==0
 assert sha(binary)==expected and plistlib.loads(plist.read_bytes())==pl
 binary.unlink();plist.unlink()
 a=call(['/bin/launchctl','print','system/com.vphone.cli.helper']);assert a.returncode!=0
 a=call(['/usr/bin/security','authorizationdb','read',right]);assert a.returncode!=0 and '-60005' in a.stderr
 a=call(['/usr/sbin/lsof','-t','--',str(binary)]);assert a.returncode==1 and not a.stdout
 assert all(not os.path.lexists(p) for p in [root,binary,plist])
 j.update(cleanup_complete=True,original_absent_baseline_restored=True,administrator_rule_never_weakened=True,upstream_VM_or_CLI_executed=False,VM_new_started=False)
except Exception as e:
 j['error']=repr(e);j['uncertain_state_preserved']=True
finally:
 out.write_text(json.dumps(j,indent=2)+'\n');os.chown(out,uid,-1)
 print(json.dumps({k:v for k,v in j.items() if k not in ['observations','installed_inventory','install_result']},indent=2),flush=True)

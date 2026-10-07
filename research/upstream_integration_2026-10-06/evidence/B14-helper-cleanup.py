import hashlib,json,os,plistlib,stat,subprocess,time
from pathlib import Path
assert os.geteuid()==0
label='com.vphone.cli.helper';right=label+'.privileged';binary=Path('/Library/PrivilegedHelperTools')/label;plist=Path('/Library/LaunchDaemons')/(label+'.plist');expected='728b03532d1792cf2ef54077ac98cbcece910a55b367d00af1e3178e383b60ce'
rows=[]
def call(args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=15);rows.append({'command':args,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr});return p
assert json.loads(Path('/private/tmp/vphone-b14-preflight.json').read_text())['fresh_helper_and_right_absent']
for p in [binary,plist]:
 s=p.lstat();assert stat.S_ISREG(s.st_mode) and s.st_uid==0 and not s.st_mode&0o022
assert hashlib.sha256(binary.read_bytes()).hexdigest()==expected
pl=plistlib.loads(plist.read_bytes());assert pl['Label']==label and pl['MachServices'][label] is True
assert pl.get('Program')==str(binary) or pl.get('ProgramArguments',[None])[0]==str(binary)
x=call(['/usr/bin/security','authorizationdb','read',right]);assert x.returncode==0;rule=plistlib.loads(x.stdout.encode());assert rule['class']=='user' and rule['group']=='admin' and rule['authenticate-user'] and not rule['allow-root'] and not rule['shared']
x=call(['/bin/launchctl','bootout','system',str(plist)]);assert x.returncode==0
x=call(['/usr/bin/security','authorizationdb','remove',right]);assert x.returncode==0
assert hashlib.sha256(binary.read_bytes()).hexdigest()==expected and plistlib.loads(plist.read_bytes())==pl
binary.unlink();plist.unlink()
x=call(['/bin/launchctl','print','system/'+label]);assert x.returncode!=0 and 'Could not find service' in x.stderr
x=call(['/usr/bin/security','authorizationdb','read',right]);assert x.returncode!=0 and '-60005' in x.stderr
p=call(['/bin/ps','-p','68514','-o','pid=,command=']);assert p.returncode!=0
result={'observations':rows,'temporary_service_removed':True,'temporary_right_removed':True,'temporary_root_owned_binary_and_plist_removed':True,'original_absent_baseline_restored':True,'no_Bundle_installed':True};p=Path('/private/tmp/vphone-b14-helper-cleanup.json');assert not p.exists();p.write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k!='observations'})

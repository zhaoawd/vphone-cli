import hashlib,json,os,subprocess,time
from pathlib import Path
r=Path('/private/tmp/vphone-b28-t24');rows=[]
def run(args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=20);row={'argv':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr};rows.append(row);(r/'cleanup-actions.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(row),flush=True);return p
installed=Path('/Library/PrivilegedHelperTools/com.vphone.cli.helper');job=Path('/Library/LaunchDaemons/com.vphone.cli.helper.plist');logs=Path('/private/var/tmp/vphone-b28-t24-system')
assert hashlib.sha256(installed.read_bytes()).hexdigest()=='b9f7383e73892dbb6a89931ec233c84a4028dce4cc3a52a42ca34358e21723b4'
assert job.read_bytes()==(r/'System-Launchd.prepared.plist').read_bytes()
p=run(['/bin/launchctl','bootout','system/com.vphone.cli.helper']);assert p.returncode==0
time.sleep(1)
for name in ['helper.stdout.log','helper.stderr.log']:
 p=logs/name
 if p.exists():(r/('system-'+name)).write_bytes(p.read_bytes())
job.unlink();installed.unlink()
p=run(['/usr/bin/security','authorizationdb','remove','com.vphone.cli.helper.privileged']);assert p.returncode==0
for p in logs.iterdir():assert p.name in ['helper.stdout.log','helper.stderr.log'];p.unlink()
logs.rmdir()
p=run(['/bin/launchctl','print','system/com.vphone.cli.helper']);assert p.returncode==113
p=run(['/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged']);assert '-60005' in p.stderr
assert not installed.exists() and not job.exists() and not logs.exists()
(r/'cleanup-complete.json').write_text(json.dumps({'job_absent':True,'installed_helper_absent':True,'launchd_plist_absent':True,'authorization_right_absent':True,'system_log_directory_absent':True},indent=2)+'\n')

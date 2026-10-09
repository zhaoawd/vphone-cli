import hashlib,json,os,plistlib,stat,subprocess,time
from pathlib import Path
root=Path('/private/tmp/vphone-b28-t24');rows=[]
(root/'runtime-authorization.json').write_text(json.dumps({'user_reply':'授权上述单一候选范围','helper_cdhash':'c49d6e2018641d6aff8001310cca0d1a62420adb','client_cdhash':'5160c4728d322314187a4cb187b3316d87087c6f','scope':'Temporary system helper v1 six-row refusal matrix, restore missing job/files/right baseline; no AMFI/TCC modification','time':time.time()},ensure_ascii=False,indent=2)+'\n')
def run(args,check=True):
 p=subprocess.run(args,capture_output=True,text=True,timeout=25);r={'argv':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr};rows.append(r);(root/'deployment-actions.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps({'argv':args,'exit':p.returncode,'stdout':p.stdout[:300],'stderr':p.stderr[:300]}),flush=True)
 if check:assert p.returncode==0,r
 return p
assert hashlib.sha256((root/'com.vphone.cli.helper').read_bytes()).hexdigest()=='b9f7383e73892dbb6a89931ec233c84a4028dce4cc3a52a42ca34358e21723b4'
assert hashlib.sha256((root/'final-client.app/Contents/MacOS/vphone-cli').read_bytes()).hexdigest()=='0422726dff884254f8c2cde09b4a59c28d73db7130e3f3746ed4cbc32cddb468'
for p in ['/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist','/private/var/tmp/vphone-b28-t24-system']:assert not os.path.lexists(p),p
for p in ['/Library','/Library/PrivilegedHelperTools','/Library/LaunchDaemons','/private/var/tmp']:
 if p=='/Library/PrivilegedHelperTools' and not os.path.lexists(p):continue
 st=os.lstat(p);assert stat.S_ISDIR(st.st_mode) and st.st_uid==0 and not st.st_mode&0o022 if p!='/private/var/tmp' else stat.S_ISDIR(st.st_mode) and st.st_uid==0
p=run(['/bin/launchctl','print','system/com.vphone.cli.helper'],False);assert p.returncode==113
p=run(['/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged'],False);assert '-60005' in p.stderr
req='anchor apple generic and identifier "com.vphone.cli.helper" and certificate leaf[subject.OU] = "3AA3QL69MQ"'
run(['/usr/bin/codesign','--verify','--deep','--strict','-R='+req,str(root/'com.vphone.cli.helper')])
run([str(root/'com.vphone.cli.helper'),'--check-configuration'])
for args in [
['/usr/bin/install','-d','-o','root','-g','wheel','-m','0755','/Library/PrivilegedHelperTools'],
['/usr/bin/install','-d','-o','root','-g','wheel','-m','0700','/private/var/tmp/vphone-b28-t24-system'],
['/usr/bin/install','-o','root','-g','wheel','-m','0755',str(root/'com.vphone.cli.helper'),'/Library/PrivilegedHelperTools/com.vphone.cli.helper'],
['/usr/bin/install','-o','root','-g','wheel','-m','0644',str(root/'System-Launchd.prepared.plist'),'/Library/LaunchDaemons/com.vphone.cli.helper.plist'],
['/bin/launchctl','bootstrap','system','/Library/LaunchDaemons/com.vphone.cli.helper.plist'],
['/bin/launchctl','kickstart','system/com.vphone.cli.helper']]:run(['/usr/bin/sudo','-n']+args)
time.sleep(1)
p=run(['/bin/launchctl','print','system/com.vphone.cli.helper']);(root/'runtime-job.txt').write_text(p.stdout)
p=run(['/usr/bin/sudo','-n','/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged']);(root/'runtime-right.plist').write_text(p.stdout);v=plistlib.loads(p.stdout.encode())
for k,val in {'class':'user','group':'admin','authenticate-user':True,'timeout':300,'shared':False,'allow-root':False,'version':1}.items():assert v.get(k)==val,(k,v.get(k))
assert 'rule' not in v
assert hashlib.sha256(Path('/Library/PrivilegedHelperTools/com.vphone.cli.helper').read_bytes()).hexdigest()=='b9f7383e73892dbb6a89931ec233c84a4028dce4cc3a52a42ca34358e21723b4'
print('AUTHORIZED_V1_DEPLOYMENT_READY',flush=True)

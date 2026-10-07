import concurrent.futures,hashlib,json,plistlib,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');exe=r/'.build/acceptance/B13/helper-client.app/Contents/MacOS/vphone-cli';helper=r/'.build/acceptance/B13/helper-client.app/Contents/Library/LaunchServices/com.vphone.cli.helper';rows=[]
def call(name,args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=45);Path('/private/tmp/vphone-b14-'+name+'.log').write_text(p.stdout+p.stderr);return {'name':name,'command':args,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
installed=Path('/Library/PrivilegedHelperTools/com.vphone.cli.helper');assert installed.read_bytes()==helper.read_bytes()
rows.append(call('helper-status',[str(exe),'helper','status']));assert rows[-1]['returncode']==0 and 'protocol: 2' in rows[-1]['stdout']
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:rows+=list(pool.map(lambda n:call('helper-verify-'+str(n),[str(exe),'helper','verify-bundle','--version','2.6.0']),[1,2]))
for x in rows[1:]:assert x['returncode']!=0 and 'Verifying Core Bundle 2.6.0' in x['stderr'] and 'timed out' not in x['stderr'].lower()
rows.append(call('helper-launchd',['/bin/launchctl','print','system/com.vphone.cli.helper']));assert rows[-1]['returncode']==0
rows.append(call('helper-rule',['/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged']));assert rows[-1]['returncode']==0
rule=plistlib.loads(rows[-1]['stdout'].encode());assert rule['class']=='user' and rule['group']=='admin' and rule['authenticate-user'] and not rule['allow-root'] and not rule['shared'] and rule['timeout']==300
result={'observations':rows,'installed_helper_matches_frozen_bytes':True,'helper_sha256':hashlib.sha256(installed.read_bytes()).hexdigest(),'service_registered':True,'root_helper_running':True,'protocol':2,'two_real_signed_clients_received_streamed_missing_store_errors':True,'verification_successful_bundle_claimed':False,'Bundle_installed':False,'authorization_rule_intact':True,'ACK_inference':'Streaming service sends operation error only after output.finish acknowledgement; both clients received underlying store error, not ACK/transport timeout.'};Path('/private/tmp/vphone-b14-helper-probe.json').write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k!='observations'})

import hashlib,json,os,subprocess
from pathlib import Path
r=Path('/private/tmp/vphone-b28-t24');rows=[]
for args in [['/bin/launchctl','print','system/com.vphone.cli.helper'],['/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged']]:
 p=subprocess.run(args,capture_output=True,text=True);rows.append({'argv':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
assert rows[0]['exit']==113 and '-60005' in rows[1]['stderr']
paths=['/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist','/private/var/tmp/vphone-b28-t24-system'];assert all(not os.path.lexists(p) for p in paths)
p=subprocess.run(['/bin/ps','-axo','pid,ppid,uid,stat,command'],capture_output=True,text=True,check=True);processes=[x for x in p.stdout.splitlines() if len(x.split(None,4))==5 and x.split(None,4)[4].startswith('/Library/PrivilegedHelperTools/com.vphone.cli.helper')];assert not processes
repo=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');original={'.build/acceptance/B13/prior-helper-candidate/com.vphone.cli.helper':'bbc0917c2d5551de48b2eff7db8396c1c1d9a7d62f48eecdacf66a82da48b3c4','.build/vphone-cli.app/Contents/MacOS/vphone-cli':'8d18f0e6a65dcd963c41a2c81c43f56922f425f708b0dba086778c7bbf458714'}
for path,expected in original.items():assert hashlib.sha256((repo/path).read_bytes()).hexdigest()==expected
result={'checks':rows,'missing_paths':paths,'helper_processes':processes,'original_hashes_unchanged':original,'independent_cleanup_verified':True,'first_readback_error':'Initial substring ps filter matched its own shell command text; exact executable-prefix filter used in final readback.'};(r/'independent-final-readback.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))

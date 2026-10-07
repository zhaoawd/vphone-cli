import hashlib,json,subprocess
from pathlib import Path
rows=[]
for name,c in [('helper-service',['/bin/launchctl','print','system/com.vphone.cli.helper']),('helper-right',['/usr/bin/security','authorizationdb','read','com.vphone.cli.privileged']),('amfi-candidate-log',['/usr/bin/log','show','--last','5m','--style','compact','--predicate','process == "amfid" AND (eventMessage CONTAINS "6ae3461ec4dae85f9375bdba4f8b7052ea9257ff" OR eventMessage CONTAINS "acceptance/B13")'])]:
 p=subprocess.run(c,capture_output=True,text=True,timeout=30);Path('/private/tmp/vphone-b13-'+name+'.log').write_text(p.stdout+p.stderr);rows.append({'name':name,'command':c,'returncode':p.returncode})
files=[]
for name in ['/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist']:
 p=Path(name);exists=p.exists();r={'path':name,'exists':exists}
 if exists and p.is_file():r['sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
 files.append(r)
Path('/private/tmp/vphone-b13-security-baseline.json').write_text(json.dumps({'observations':rows,'files':files,'security_mutation_performed':False},indent=2)+'\n');print({'helper_installed_paths':files,'probe_returncodes':[(r['name'],r['returncode']) for r in rows]})

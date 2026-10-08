import hashlib,json,os,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');app=r/'.build/acceptance/B15/helper-client.app';helper=app/'Contents/Library/LaunchServices/com.vphone.cli.helper';archive=Path('/private/tmp/vphone-b18-VPhone-2.6.1.zip')
expected='728b03532d1792cf2ef54077ac98cbcece910a55b367d00af1e3178e383b60ce'
assert hashlib.sha256(helper.read_bytes()).hexdigest()==expected
sig=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(helper)],capture_output=True,text=True);assert sig.returncode==0 and 'TeamIdentifier=3AA3QL69MQ' in sig.stderr and 'CDHash=30ce6ce220a60617b6ae42066372bf3ac2e8ebe6' in sig.stderr
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='651224d58064c59159e47b4a5fb066ca6dc758bdd221a346d43465cd34df5420'
paths=['/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist','/Library/Application Support/vphone-launchpad/Bundles']
assert all(not os.path.lexists(p) for p in paths)
rule=subprocess.run(['/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged'],capture_output=True,text=True);assert rule.returncode!=0 and '-60005' in rule.stderr
service=subprocess.run(['/bin/launchctl','print','system/com.vphone.cli.helper'],capture_output=True,text=True);assert service.returncode!=0
j={'fresh_helper_and_right_absent':True,'root_store_absent':True,'exact_helper_SHA256':expected,'CDHash':'30ce6ce220a60617b6ae42066372bf3ac2e8ebe6','Team_ID':'3AA3QL69MQ','archive_bytes':archive.stat().st_size,'archive_sha256':'651224d58064c59159e47b4a5fb066ca6dc758bdd221a346d43465cd34df5420','user_authorization':'2026-10-08 latest user: 授权，继续推进; follows exact B19 helper scope request','permissions_unchanged':True}
Path('/private/tmp/vphone-b20-helper-preflight.json').write_text(json.dumps(j,ensure_ascii=False,indent=2)+'\n');print(j)

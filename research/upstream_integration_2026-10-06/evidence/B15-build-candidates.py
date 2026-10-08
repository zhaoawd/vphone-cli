import hashlib,json,os,plistlib,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');root=r/'.build/acceptance/B15'
def h(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def tree(p):return {str(x.relative_to(p)):h(x) for x in p.rglob('*') if x.is_file()}
def clone(s,d):
 assert s.is_dir() and not d.exists();subprocess.run(['/bin/cp','-cR',str(s),str(d)],check=True);assert tree(s)==tree(d)
def run(name,c):
 log=Path('/private/tmp/vphone-b15-'+name+'.log');assert not log.exists()
 with log.open('w') as f:
  f.write('COMMAND '+json.dumps(c)+'\n');f.flush();x=subprocess.run(c,cwd=r,stdout=f,stderr=subprocess.STDOUT)
 print({'step':name,'returncode':x.returncode},flush=True)
 if x.returncode:raise SystemExit(x.returncode)
assert not root.exists();root.mkdir(parents=True)
assert subprocess.check_output(['git','status','--porcelain'],cwd=r,text=True)==''
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip()
assert head.startswith('ee7b9ec2')
for name,relative in [('prebuild.app','.build/vphone-cli.app'),('prior-launchpad.app','.build/vphone-launchpad.app')]:
 src=r/relative
 if src.exists():clone(src,root/name)
run('host-build',['/bin/zsh','scripts/build.sh','--no-vphoned'])
clone(r/'.build/vphone-cli.app',root/'candidate.app')
run('launchpad-build',['/bin/zsh','scripts/build_launchpad.sh'])
clone(r/'.build/vphone-launchpad.app',root/'launchpad.app')
# The signed client uses the already-authorized frozen B13 protocol-2 helper.
# No new helper executable or privileged service is installed by this build.
clone(root/'candidate.app',root/'helper-client.app')
app=root/'helper-client.app';helper=r/'.build/acceptance/B13/helper-client.app/Contents/Library/LaunchServices/com.vphone.cli.helper'
assert h(helper)=='728b03532d1792cf2ef54077ac98cbcece910a55b367d00af1e3178e383b60ce'
destination=app/'Contents/Library/LaunchServices/com.vphone.cli.helper';destination.parent.mkdir(parents=True)
subprocess.run(['/bin/cp','-c',str(helper),str(destination)],check=True);assert h(destination)==h(helper)
selection=json.loads(Path('/private/tmp/vphone-b13-signing-selection.json').read_text());team=selection['team'];identity=selection['identity']
p=app/'Contents/Info.plist';info=plistlib.loads(p.read_bytes());info['VPhoneHelperSigningTeam']=team
info['SMPrivilegedExecutables']={'com.vphone.cli.helper':f'anchor apple generic and identifier "com.vphone.cli.helper" and certificate leaf[subject.OU] = "{team}"'};p.write_bytes(plistlib.dumps(info))
for target in [app/'Contents/MacOS/vphone-cli',app]:subprocess.run(['/usr/bin/codesign','--force','--sign',identity,str(target)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',str(app)],check=True)
Path('/private/tmp/vphone-b15-build-provenance.json').write_text(json.dumps({'source_head':head,'helper_source_head':'55fd8ef57a6731e42cba0727f477bc9b25f0c9ca','helper_sha256':h(helper),'helper_CDHash':'30ce6ce220a60617b6ae42066372bf3ac2e8ebe6','helper_team':team,'new_helper_built_or_registered':False,'candidate_stage':str(root)},indent=2)+'\n')
print({'candidates_frozen_at':str(root),'source_head':head,'helper_reused_frozen_B13':True},flush=True)

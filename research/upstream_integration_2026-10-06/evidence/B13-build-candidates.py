import hashlib,json,os,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
root=r/'.build/acceptance/B13'
def h(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def tree(p):return {str(x.relative_to(p)):h(x) for x in p.rglob('*') if x.is_file()}
def clone(s,d):
 assert s.is_dir() and not d.exists()
 subprocess.run(['/bin/cp','-cR',str(s),str(d)],check=True)
 assert tree(s)==tree(d)
def run(name,c,env=None):
 log=Path('/private/tmp/vphone-b13-'+name+'.log');assert not log.exists()
 with log.open('w') as f:
  f.write('COMMAND '+json.dumps(c)+'\n');f.flush();x=subprocess.run(c,cwd=r,env=env,stdout=f,stderr=subprocess.STDOUT)
 print({'step':name,'returncode':x.returncode},flush=True)
 if x.returncode:raise SystemExit(x.returncode)
assert not root.exists();root.mkdir(parents=True)
for name,relative in [('prebuild.app','.build/vphone-cli.app'),('prior-launchpad.app','.build/vphone-launchpad.app'),('prior-helper-candidate','.build/helper-candidate')]:
 src=r/relative
 if src.exists():clone(src,root/name)
run('host-build',['/bin/zsh','scripts/build.sh','--no-vphoned'])
clone(r/'.build/vphone-cli.app',root/'candidate.app')
run('launchpad-build',['/bin/zsh','scripts/build_launchpad.sh'])
clone(r/'.build/vphone-launchpad.app',root/'launchpad.app')
selection=json.loads(Path('/private/tmp/vphone-b13-signing-selection.json').read_text());e=os.environ.copy()
e['VPHONE_HELPER_SIGNING_TEAM']=selection['team'];e['VPHONE_HELPER_SIGNING_IDENTITY']=selection['identity']
run('signed-helper-build',['/bin/zsh','scripts/build_helper_candidate.sh'],e)
clone(r/'.build/helper-candidate/vphone-cli.app',root/'helper-client.app')
print({'candidates_frozen_at':str(root),'source_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip()},flush=True)

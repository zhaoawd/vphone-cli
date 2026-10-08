import hashlib,json,re,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');stage=r/'.build/acceptance/B16';assert not stage.exists()
assert subprocess.check_output(['git','status','--porcelain'],cwd=r,text=True)==''
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip()
log=Path('/private/tmp/vphone-b16-host-build.log');assert not log.exists()
with log.open('w') as f:
 code=subprocess.run(['/bin/zsh','scripts/build.sh','--no-vphoned'],cwd=r,stdout=f,stderr=subprocess.STDOUT).returncode
assert code==0,'build failed'
stage.mkdir(parents=True);app=stage/'candidate.app';source=r/'.build/vphone-cli.app'
subprocess.run(['/bin/cp','-cR',str(source),str(app)],check=True)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
files={str(p.relative_to(app)):{'bytes':p.stat().st_size,'sha256':digest(p)} for p in sorted(app.rglob('*')) if p.is_file()}
assert {n:d['sha256'] for n,d in files.items()}=={str(p.relative_to(source)):digest(p) for p in source.rglob('*') if p.is_file()}
with Path('/private/tmp/vphone-b16-bundle-check.log').open('x') as f:
 code=subprocess.run(['/Users/qcz3840/github/vphone-cli/.venv/bin/python','-B',str(r/'scripts/check_bundle.py'),str(app),'--execute'],cwd=r,stdout=f,stderr=subprocess.STDOUT).returncode
assert code==0
vm=app/'Contents/MacOS/vphone-vm';sig=subprocess.run(['/usr/bin/codesign','-dvvv',str(vm)],capture_output=True,text=True,check=True).stderr
cdhash=re.search(r'^CDHash=(\w+)$',sig,re.M)[1]
result={'source_head':head,'stage':str(stage),'apps':{'candidate.app':{'files':files,'file_count':len(files)}},'total_files':len(files),'VM_CDHash':cdhash,'VM_SHA256':digest(vm),'VM_booted':False,'VM_help_executed':False,'new_VM_AMFI_authorization':'not yet requested; prior exact authorization applies to B15 hash only','build_and_bundle_execute_checks_passed':True,'guest_rebuilt_or_deployed':False,'helper_built_or_registered':False,'Launchpad_rebuilt':False}
Path('/private/tmp/vphone-b16-artifact-manifest.json').write_text(json.dumps(result,indent=2)+'\n')
print({k:v for k,v in result.items() if k!='apps'},flush=True)

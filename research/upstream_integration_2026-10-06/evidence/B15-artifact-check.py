import hashlib,json,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');stage=r/'.build/acceptance/B15';apps={};checks=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def command(c):
 x=subprocess.run(c,capture_output=True,text=True,timeout=30);checks.append({'command':c,'returncode':x.returncode,'stdout':x.stdout,'stderr':x.stderr});assert x.returncode==0;return x
for name in ['candidate.app','launchpad.app','helper-client.app']:
 app=stage/name;command(['/usr/bin/codesign','--verify','--strict','--deep',str(app)])
 files={str(p.relative_to(app)):{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(app.rglob('*')) if p.is_file()}
 apps[name]={'files':files,'file_count':len(files)}
launch=stage/'launchpad.app';manifest=json.loads((launch/'Contents/Resources/embedded-toolchain.json').read_text())
for name,key in [('vphone-cli','vphoneCLI'),('vphone-vm','vphoneVM')]:
 exe=launch/'Contents/Helpers/vphone-cli.app/Contents/MacOS'/name
 x=command(['/usr/bin/codesign','-dvvv',str(exe)])
 assert ('CDHash='+manifest[key]['cdhash']) in x.stderr
 assert sha(exe)==sha(stage/'candidate.app/Contents/MacOS'/name)
for verb in ['verify-bundle','install-bundle']:
 x=command([str(stage/'helper-client.app/Contents/MacOS/vphone-cli'),'helper',verb,'--help']);assert '--log-file' in x.stdout
result={'source_head':'ee7b9ec2c6be7a0402291afbf6e2eae0136c7f3b','helper_source_head':'55fd8ef57a6731e42cba0727f477bc9b25f0c9ca','helper_reused_frozen_B13':True,'stage':str(stage),'apps':apps,'total_files':sum(a['file_count'] for a in apps.values()),'checks':checks,'VM_execution_blocked':True,'VM_CDHash':'343c11ebfeab191227fe5e6b849897282c2289c7','VM_SHA256':sha(stage/'candidate.app/Contents/MacOS/vphone-vm'),'runtime_acceptance_on_new_VM_claimed':False}
Path('/private/tmp/vphone-b15-artifact-manifest.json').write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k not in ['apps','checks']})

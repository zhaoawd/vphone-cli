import hashlib,json,os,re,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');stage=r/'.build/acceptance/B13'
head=Path('/private/tmp/vphone-b13-implementation-head.txt').read_text().strip();assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip()==head
result={'source_head':head,'stage':str(stage),'apps':{},'activation_performed':False,'helper_registered':False,'amfid_operation_performed':False}
for name in ['candidate.app','launchpad.app','helper-client.app']:
 app=stage/name;v=subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',str(app)],capture_output=True,text=True);assert v.returncode==0,v.stderr
 files={}
 for p in sorted(app.rglob('*')):
  if p.is_file():
   data=p.read_bytes();files[str(p.relative_to(app))]={'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
 result['apps'][name]={'files':files,'file_count':len(files),'signature_verify':v.returncode,'executables':{}}
 exes=list((app/'Contents/MacOS').iterdir())
 if name=='helper-client.app':exes.append(app/'Contents/Library/LaunchServices/com.vphone.cli.helper')
 for p in exes:
  if not p.is_file():continue
  cmd=['/usr/bin/codesign','-dvvv','--entitlements',':-',str(p)];info=subprocess.run(cmd,capture_output=True,text=True);combined=info.stdout+info.stderr
  digest=re.search(r'^CDHash=(\w+)$',combined,re.M)
  if digest:
   entry={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'cdhash':digest[1], 'path':str(p)}
   result['apps'][name]['executables'][p.name]=entry
   Path('/private/tmp/vphone-b13-'+name+'-'+p.name+'-codesign.log').write_text(combined)
assert result['apps']['candidate.app']['executables']['vphone-vm']['sha256']==result['apps']['helper-client.app']['executables']['vphone-vm']['sha256']
for name,exe,args in [('candidate-cli-help',stage/'candidate.app/Contents/MacOS/vphone-cli',['--help']),('candidate-vm-help',stage/'candidate.app/Contents/MacOS/vphone-vm',['--help']),('helper-configuration',stage/'helper-client.app/Contents/Library/LaunchServices/com.vphone.cli.helper',['--check-configuration'])]:
 x=subprocess.run([str(exe),*args],cwd=r,capture_output=True,text=True,timeout=30)
 Path('/private/tmp/vphone-b13-'+name+'.log').write_text(x.stdout+x.stderr)
 result[name]={'returncode':x.returncode,'read_only':True}
old=json.loads((r/'research/upstream_integration_2026-10-06/evidence/B09-artifact-manifest.json').read_text());count=0
for name in ['baseline.app','candidate.app','launchpad.app']:
 for relative,record in old[name]['files'].items():
  data=(r/'.build/acceptance/B09'/name/relative).read_bytes();assert len(data)==record['bytes'] and hashlib.sha256(data).hexdigest()==record['sha256'];count+=1
result['old_B09_files_verified']=count
p=Path('/private/tmp/vphone-b13-artifact-manifest.json');assert not p.exists();p.write_text(json.dumps(result,indent=2)+'\n')
print({'source_head':head,'candidate_VM':result['apps']['candidate.app']['executables']['vphone-vm'],'candidate_VM_help':result['candidate-vm-help'],'signed_helper_configuration':result['helper-configuration'],'helper':result['apps']['helper-client.app']['executables']['com.vphone.cli.helper'],'B09_files_verified':count,'new_artifact_file_count':sum(x['file_count'] for x in result['apps'].values())})

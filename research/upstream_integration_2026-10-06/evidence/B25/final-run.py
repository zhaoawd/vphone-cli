from pathlib import Path
import sys,subprocess,time,json,re
base=Path('/private/tmp/vphone-b25');repo=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');name=sys.argv[1];commands={'python':['make','test_python'],'build':['make','launchpad','check_bundle','check_launchpad']};assert name in commands
start=time.monotonic()
with (base/f'{name}-final.log').open('w') as f:p=subprocess.run(commands[name],cwd=repo,stdout=f,stderr=subprocess.STDOUT)
r={'entrypoint':' '.join(commands[name]),'exit':p.returncode,'seconds':time.monotonic()-start,'log':f'B25/{name}-final.log','source_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()}
if name=='python':
 text=(base/'python-final.log').read_text();m=re.search(r'Ran (\d+) tests in ([\d.]+)s',text);skip=re.search(r'OK \(skipped=(\d+)\)',text)
 if m:r.update({'tests':int(m[1]),'suite_seconds':float(m[2]),'skipped':int(skip[1]) if skip else 0})
(base/f'{name}-result.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r),flush=True)
raise SystemExit(p.returncode)

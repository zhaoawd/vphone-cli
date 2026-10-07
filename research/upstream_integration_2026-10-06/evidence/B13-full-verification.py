import subprocess
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
python='/Users/qcz3840/github/vphone-cli/.venv/bin/python'
results=[]
for suite in ['python','swift']:
 path=Path('/private/tmp/vphone-b13-final-'+suite+'.log')
 assert not path.exists()
 with path.open('xb') as f:
  result=subprocess.run([python,'-B','scripts/run_tests.py',suite],cwd=root,stdout=f,stderr=subprocess.STDOUT)
 results.append({'suite':suite,'returncode':result.returncode,'log':str(path)})
 print(results[-1],flush=True)
import json
Path('/private/tmp/vphone-b13-final-suite-results.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(any(x['returncode'] for x in results))

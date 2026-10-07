import json,hashlib,subprocess
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
sha=lambda b:hashlib.sha256(b).hexdigest()
samples=[]
for i in range(8):
 b=subprocess.check_output([str(root/'.build/debug/vphone-cli'),'fw','plan','--variant','regular','--json'],cwd=root)
 p=json.loads(b)[0]
 assert p['enabledSteps']==sorted(p['enabledSteps'])
 samples.append({'sample':i,'steps_count':len(p['enabledSteps']),
   'step_set_sha256':sha(json.dumps(sorted(p['enabledSteps']),separators=(',',':')).encode()),
   'encoded_steps_sha256':sha(json.dumps(p['enabledSteps'],separators=(',',':')).encode()),
   'plan_json_sha256':sha(b)})
result={'samples':samples,'distinct_order_digests':len({s['encoded_steps_sha256'] for s in samples}),
 'distinct_sets':len({s['step_set_sha256'] for s in samples}),
 'distinct_plan_json_digests':len({s['plan_json_sha256'] for s in samples}),
 'scope':'eight independent read-only CLI processes; no persistence or VM operations'}
assert result['distinct_order_digests']==result['distinct_sets']==result['distinct_plan_json_digests']==1
Path('/private/tmp/vphone-t11-canonical-cli-20261007.json').write_text(json.dumps(result,indent=2)+'\n')
print('8 CLI processes: one step-order digest, one step-set digest, one complete JSON digest')

import hashlib,json,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');b=r/'research/upstream_integration_2026-10-06';head='55fd8ef57a6731e42cba0727f477bc9b25f0c9ca';up='2d21d21fbdd4f51f013616273ceda9b35a3e0789'
refs=json.loads((b/'evidence/B12-source-review.json').read_text())['references']
for group in refs.values():
 for x in group:
  data=subprocess.check_output(['git','--git-dir=/private/tmp/vphone-upstream-proxy-20261006','show',up+':'+x['path']]);assert len(data)==x['bytes'] and hashlib.sha256(data).hexdigest()==x['sha256']
local=[]
for name in json.loads(Path('/private/tmp/vphone-b13-source-files.json').read_text()):
 p=r/name;data=p.read_bytes();assert subprocess.check_output(['git','show',head+':'+name],cwd=r)==data;local.append({'path':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
x={'upstream_revision':up,'implementation_head':head,'references':refs,'local_changed_files':local,'reference_count':sum(map(len,refs.values())),'semantic_commit_ledger_changed':False,'local_adaptation':'Existing local module boundaries and classic guest compatibility are preserved. New shared Core types, API-only guest mode and helper protocol2 are local adaptations; source references do not prove complete capability equivalence.'}
Path('/private/tmp/vphone-b13-source-review.json').write_text(json.dumps(x,indent=2)+'\n');print({'verified_upstream_references':x['reference_count'],'verified_committed_source_files':len(local)})

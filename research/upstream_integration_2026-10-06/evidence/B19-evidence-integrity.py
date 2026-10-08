import hashlib,json
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');b=r/'research/upstream_integration_2026-10-06'
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
 return h.hexdigest()
old=json.loads((b/'evidence/manifest.json').read_text());assert len(old)==1084
for x in old:
 p=b/x['path'];assert p.stat().st_size==x['bytes'] and sha(p)==x['sha256'],p
inputs=json.loads((b/'input_manifest.json').read_text())
for x in inputs:
 p=r/x['copy'];assert p.stat().st_size==x['bytes'] and sha(p)==x['sha256'],p
n=0
for name in ['B15-artifact-manifest.json','B16-artifact-manifest.json']:
 j=json.loads((b/'evidence'/name).read_text())
 for app,details in j['apps'].items():
  for rel,x in details['files'].items():
   p=Path(j['stage'])/app/rel;assert p.stat().st_size==x['bytes'] and sha(p)==x['sha256'],p;n+=1
j={'old_evidence_reverified':len(old),'input_copies_reverified':len(inputs),'B15_B16_frozen_files_reverified':n}
Path('/private/tmp/vphone-b19-evidence-integrity.json').write_text(json.dumps(j,indent=2)+'\n');print(j)

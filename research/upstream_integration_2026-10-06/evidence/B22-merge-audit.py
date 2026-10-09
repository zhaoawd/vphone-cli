import hashlib,json,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/research/upstream_integration_2026-10-06');ledger=json.loads((r/'commit_ledger.json').read_text());reviews={x['sha']:x for x in json.loads((r/'T02_merge_resolution_reviews.json').read_text())['reviews']};rows=[]
for c in ledger['commits']:
 if not c['merge']:continue
 p=subprocess.run(['git','-C','/private/tmp/vphone-upstream-proxy-20261006','show','--remerge-diff','--format=','--no-ext-diff',c['sha']],capture_output=True);assert p.returncode==0,p.stderr
 x={'sha':c['sha'],'subject':c['subject'],'parents':c['parents'],'bytes':len(p.stdout),'remerge_sha256':hashlib.sha256(p.stdout).hexdigest(),'additional_resolution':bool(p.stdout)}
 if p.stdout:
  assert c['sha'] in reviews,c['sha'];review=reviews[c['sha']];saved=r/review['evidence'];x['existing_review']=review
  old=saved.read_bytes();x['saved_evidence_sha256']=hashlib.sha256(old).hexdigest()
  output=Path('/private/tmp/vphone-b22-remerge-'+c['sha'][:8]+'.diff');output.write_bytes(p.stdout);x['fresh_diff']=str(output)
 rows.append(x)
Path('/private/tmp/vphone-b22-merge-audit.json').write_text(json.dumps({'scope':'All 62 merge commits; automatic remerge compared with recorded merge tree; parent commits still require semantic review','merges':rows},indent=2)+'\n');print({'merges':len(rows),'empty':sum(not x['additional_resolution'] for x in rows),'nonempty':sum(x['additional_resolution'] for x in rows)})

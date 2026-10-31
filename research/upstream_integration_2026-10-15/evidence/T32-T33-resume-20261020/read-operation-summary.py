import json
from pathlib import Path
p=Path('/Users/kolar/github/vphone-cli/vm-t32-t33-dsc-20261018/.cfw-history/20261020T000756Z-iTDO2qSV')
rows=[json.loads(line) for line in (p/'guest-changes.jsonl').read_text().splitlines()]
print(json.dumps({'rows':len(rows),'lastOperations':[{'target':r.get('target'),'path':r.get('path'),'declarationID':r.get('declarationID'),'phase':r.get('phase'),'effect':{k:r.get('effect',{}).get(k) for k in ['operation','command','operationID']}} for r in rows[-14:]]},indent=2))

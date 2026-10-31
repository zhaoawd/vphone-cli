import json
from pathlib import Path
root=Path('/Users/kolar/github/vphone-cli')
folder=root/'vm-t32-t33-dsc-20261018/.cfw-history/20261020T000756Z-iTDO2qSV'
result={'transaction':'20261020T000756Z-iTDO2qSV','files':[],'records':{}}
for p in sorted(folder.iterdir()):
    result['files'].append({'name':p.name,'bytes':p.lstat().st_size})
    if p.name in {'transaction.json','failure.json','error.json'} and p.is_file():
        result['records'][p.name]=json.loads(p.read_text())
print(json.dumps(result,ensure_ascii=False,indent=2))

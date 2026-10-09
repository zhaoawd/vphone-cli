import hashlib,json,pathlib,subprocess
P=pathlib.Path;OUT=P('/private/tmp/vphone-b28-t40');ROOT=OUT/'runtime-v1'; repo=P('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
report={'declared_source':'b4e80c57','observed_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'files':[]}
for name in ['requirements.txt','scripts/check_python_runtime.py','dependencies/python-darwin-arm64-3.14.lock','dependencies/python-darwin-arm64-3.14.json','scripts/pymobiledevice3_bridge.py']:
 original=subprocess.check_output(['git','show','b4e80c57:'+name],cwd=repo)
 copied=(ROOT/'project'/name).read_bytes()
 report['files'].append({'path':name,'declared_source_sha256':hashlib.sha256(original).hexdigest(),'copied_sha256':hashlib.sha256(copied).hexdigest(),'same':original==copied})
(OUT/'source-identity.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))

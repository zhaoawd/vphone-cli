"""Diagnostic replay: preserved bytes real; final stat observation from journal."""
import json
from pathlib import Path
import sys
from unittest.mock import patch
sys.path.insert(0,str(Path.cwd()/'scripts'))
from patchers import component_effects as effects
archive=Path('vm-t32-t33-20261018-r2/.cfw-history/20261018T234718Z-5V5rPsLR')
entries=json.loads(Path('.build/t32-metadata-debug/transport-histories.json').read_text())
original_state=effects.state
failures=[]
for entry in entries:
 if entry['target'] not in ('system:/usr/libexec/seputil','system:/usr/libexec/launchd_cache_loader','system:/usr/libexec/mobileactivationd'):continue
 final=entry['final'];path=archive/'effect-blobs'/final['sha256']
 def observed(candidate,*args,**kwargs):
  if Path(candidate)==path:return final
  return original_state(candidate,*args,**kwargs)
 try:
  with patch.object(effects,'state',side_effect=observed):effects.verify(entry['proofs'],path,archive/'effect-blobs')
 except ValueError as error:failures.append({'target':entry['target'],'error':str(error)});print(entry['target'],str(error),flush=True)
 else:print(entry['target'],'passed',flush=True)
Path('.build/t32-metadata-debug/replay-result.json').write_text(json.dumps({'failures':failures},indent=2)+'\n')
raise SystemExit(bool(failures))

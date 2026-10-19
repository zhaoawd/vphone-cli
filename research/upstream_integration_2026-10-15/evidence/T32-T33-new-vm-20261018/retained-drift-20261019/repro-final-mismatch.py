import json,sys,tempfile,shutil
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0,'scripts')
from patchers import component_transport as transport,component_effects as effects
archive=Path('vm-t32-t33-dsc-20261018/.cfw-history/20261019T081934Z-JTYX6fft')
rows=[json.loads(line) for line in (archive/'guest-changes.jsonl').read_bytes().splitlines()]
row=next(member for row in rows for member in transport.expanded(row) if member['target'].endswith('/dyld_shared_cache_arm64e.42'))
# Minimise to final transport equality; source-image qualification is unchanged
# in production and does not choose this comparison's expected final state.
row={k:v for k,v in row.items() if k not in ('sourceImage','sourceImageProof')}
with tempfile.TemporaryDirectory(dir='/private/tmp') as d:
 root=Path(d);target=root/row['target'].split(':',1)[1].lstrip('/');target.parent.mkdir(parents=True)
 shutil.copyfile(archive/'effect-blobs'/row['effect']['after']['sha256'],target)
 # Keep the independently captured uid/gid through a state observer; bytes come
 # from the real preserved blob. One changed digest drives the actual guard.
 from unittest.mock import patch
 observed=dict(row['effect']['after']);observed['sha256']='0'*64
 with patch.object(effects,'state',return_value=observed):
  transport.verify([row],{'system':root},archive/'effect-blobs',SimpleNamespace(context={}))

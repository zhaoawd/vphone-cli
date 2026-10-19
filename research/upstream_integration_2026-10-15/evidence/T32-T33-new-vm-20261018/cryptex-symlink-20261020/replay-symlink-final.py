"""Replay two real deletion observations against the real installer link seam."""
import json,sys
from pathlib import Path
from types import SimpleNamespace
sys.path[:0]=[str(Path.cwd()),str(Path.cwd()/'scripts')]
from tests.test_cfw_cryptex_reinstall import CryptexReinstallTests
from patchers import component_transport as transport
archive=Path('vm-t32-t33-dsc-20261018/.cfw-history/20261019T124601Z-vZh3Hh4C')
rows=[json.loads(line) for line in (archive/'guest-changes.jsonl').read_bytes().splitlines()]
tombstones=[row for row in transport.expanded(rows[1]) if row['target'].endswith(('com.apple.dyld/com.apple.dyld','dyld/dyld'))]
assert len(tombstones)==2
fixture=CryptexReinstallTests()
try:
 child,root,_=fixture.run_installer('1',existing_symlinks=True)
 assert child.returncode==75,child.stderr
 for row in tombstones:row['path']=str(root/row['target'].split(':',1)[1].lstrip('/'))
 outputs=transport.verify(tombstones,{'system':root},root/'unused-blobs',SimpleNamespace(context={}))
 assert all(row['state']=={'kind':'missing'} for row in outputs)
 print('PASS: real deletion observations survive reinstall with existing directory symlinks')
finally:fixture.doCleanups()

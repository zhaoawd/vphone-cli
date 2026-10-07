import hashlib,json,subprocess
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');b=r/'research/upstream_integration_2026-10-06'
def git(*a):return subprocess.check_output(['git',*a],cwd=r)
assert git('rev-parse','HEAD').decode().strip()=='dd3c800277605589ae1cb2466a2b33fa33e549d1'
for row in json.loads((b/'evidence/manifest.json').read_text()):
 data=(b/row['path']).read_bytes();assert len(data)==row['bytes'] and hashlib.sha256(data).hexdigest()==row['sha256']
 assert git('show','HEAD:research/upstream_integration_2026-10-06/'+row['path'])==data
for row in json.loads((b/'input_manifest.json').read_text()):
 data=(r/row['copy']).read_bytes();assert hashlib.sha256(data).hexdigest()==row['sha256'] and git('show','HEAD:'+row['copy'])==data
assert 'Test run with 54 tests in 8 suites passed' in Path('/private/tmp/vphone-b13-disk-release-green2.log').read_text()
assert 'Test run with 13 tests in 3 suites passed' in Path('/private/tmp/vphone-b13-history-helper-green2.log').read_text()
assert 'Test run with 1234 tests in 198 suites passed' in Path('/private/tmp/vphone-b13-swiftpm-serial.log').read_text()
assert 'Ran 571 tests' in Path('/private/tmp/vphone-b13-final-python.log').read_text()
subprocess.run(['git','diff','--check'],cwd=r,check=True)
paths=[]
for entry in git('status','--porcelain=v1','-z').split(b'\0'):
 if not entry:continue
 assert entry[:2] in [b' M',b'??'];path=entry[3:].decode();assert path in ['Package.swift','scripts/build_helper_candidate.sh'] or path.startswith(('sources/','tests/'))
 paths.append(path)
assert len(paths)>40
subprocess.run(['git','add','--',*paths],cwd=r,check=True)
subprocess.run(['git','commit','-m','feat: connect startup unlock, guest shutdown, clipboard, binding and output ACK'],cwd=r,check=True)
head=git('rev-parse','HEAD').decode().strip();Path('/private/tmp/vphone-b13-implementation-head.txt').write_text(head+'\n')
Path('/private/tmp/vphone-b13-source-files.json').write_text(json.dumps(paths,indent=2)+'\n')
print({'implementation_head':head,'changed_source_paths':len(paths),'old_evidence_preserved':577})

#!/usr/bin/env python3
"""Package the completed signed app with the verified historical escalator; never install or execute it."""
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path('/Users/qcz3840/github/vphone-cli')
BUILD = Path('/private/tmp/vphone-task8-acceptance-build')
EVIDENCE = ROOT / 'research/evidence/2026-10-13-task8/acceptance'
STAGE = BUILD / 'core-candidate-v4'
BUNDLE = STAGE / 'VPhone.bundle'
ARCHIVE = STAGE / 'VPhone.zip'
VERSION = '2.6.20261016-local'
HISTORICAL = Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/acceptance/B22/local-core')
EXPECTED_ARCHIVE = '178e2e16de6bd45388f3be7f089edcf200fbf5d8bdcabe5c3134b4036d537fde'
EXPECTED_ESCALATOR = '12b964b4e2100110c525d68a677de26f62044e19fc1dc4ffe8b2ca6e1ce52fdc'
observations = []


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args):
    p = subprocess.run(args, capture_output=True, text=True)
    observations.append({'command':list(args),'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    if p.returncode:
        raise RuntimeError(observations[-1])
    return p.stdout + p.stderr


assert sha(HISTORICAL / 'VPhone.zip') == EXPECTED_ARCHIVE
with zipfile.ZipFile(HISTORICAL / 'VPhone.zip') as archive:
    assert hashlib.sha256(archive.read('VPhone.bundle/Contents/MacOS/vphone-escalator')).hexdigest() == EXPECTED_ESCALATOR
assert not STAGE.exists(), 'Use a fresh stage; existing frozen candidate is never replaced.'
STAGE.mkdir()
run('/bin/cp','-cR',str(BUILD / '.build/vphone-cli.app'),str(BUNDLE))
old = HISTORICAL / 'VPhone.bundle'
escalator = BUNDLE / 'Contents/MacOS/vphone-escalator'
shutil.copy2(old / 'Contents/MacOS/vphone-escalator', escalator)
assert sha(escalator) == EXPECTED_ESCALATOR
shutil.copy2(old / 'Contents/Resources/scripts/licenses/vphone-escalator-MIT.txt', BUNDLE / 'Contents/Resources/scripts/licenses/vphone-escalator-MIT.txt')
provenance = json.loads((EVIDENCE / 'escalator-provenance.json').read_text())
provenance.update({'store_version':VERSION, 'component_usage':'Historical local build from upstream 2d21d21; included for store layout; not executed.', 'host_source_manifest_sha256':sha(EVIDENCE / 'build-source-v4-manifest.json')})
(BUNDLE / 'Contents/Resources/task8-candidate-provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
run('/usr/bin/codesign','--force','--sign','-',str(BUNDLE))
run(sys.executable,str(BUILD / 'scripts/build_native_dependencies.py'),str(BUNDLE),'--check')
run(sys.executable,str(BUILD / 'scripts/record_build_dependencies.py'),str(BUNDLE))
run('/usr/bin/codesign','--force','--sign','-',str(BUNDLE))
run(sys.executable,str(BUILD / 'scripts/check_bundle.py'),str(BUNDLE))
run('/usr/bin/codesign','--verify','--strict','--deep',str(BUNDLE))
artifacts={}
for name in ['vphone-cli','vphone-vm','vphone-escalator']:
    p=BUNDLE / 'Contents/MacOS' / name
    run('/usr/bin/codesign','--verify','--strict',str(p))
    detail=run('/usr/bin/codesign','-dvvv',str(p))
    artifacts[name]={'path':str(p),'sha256':sha(p),'cdhash':next(x.split('=',1)[1] for x in detail.splitlines() if x.startswith('CDHash=')),'architectures':run('/usr/bin/lipo','-archs',str(p)).strip()}
assert artifacts['vphone-escalator']['sha256'] == EXPECTED_ESCALATOR
run('/usr/bin/ditto','-c','-k','--keepParent','--norsrc',str(BUNDLE),str(ARCHIVE))
report={'bundle':str(BUNDLE),'archive':str(ARCHIVE),'version':VERSION,'archive_sha256':sha(ARCHIVE),'artifacts':artifacts,'observations':observations,'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'installed':False,'escalator_executed':False,'files_sha256':{str(p.relative_to(BUNDLE)):sha(p) for p in sorted(BUNDLE.rglob('*')) if p.is_file()}}
(EVIDENCE/'core-candidate-v4-manifest.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({key:report[key] for key in ['bundle','archive','version','archive_sha256','artifacts']},indent=2))

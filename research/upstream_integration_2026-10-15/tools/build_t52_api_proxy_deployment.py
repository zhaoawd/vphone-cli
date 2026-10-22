#!/usr/bin/env python3
"""Package the committed APIProxy repair on the accepted local resource base.

This builds no guest payload, installs nothing, and never starts a VM.
Release CLI/VM builds must already have completed for source-before-build.json.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-api-proxy-deploy-20261022'
baseline = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.af333c78ac3b/VPhone.bundle')
bundle = work / 'package/VPhone.bundle'
if bundle.exists():
    raise SystemExit('Preserve the existing package; choose a new path')
run = lambda *args: subprocess.run([str(arg) for arg in args], cwd=root, check=True)
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
provenance = json.loads((work / 'source-before-build.json').read_text())
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
assert commit == provenance['commit']
for name, expected in provenance['workspaceSourceSHA256'].items():
    assert digest(root / name) == expected, 'Source changed during build: ' + name
for name in ('sources/VPhoneAPIKit/VPhoneAPIProxy.swift', 'tests/VPhoneAPIKitTests/APIProxyTests.swift'):
    committed = subprocess.check_output(['git', 'show', commit + ':' + name], cwd=root)
    assert hashlib.sha256(committed).hexdigest() == digest(root / name), name
bundle.parent.mkdir()
run('/usr/bin/ditto', baseline, bundle)
for name in ('vphone-cli', 'vphone-vm'):
    target = bundle / 'Contents/MacOS' / name
    shutil.copy2(root / '.build/release' / name, target)
    arguments = ['/usr/bin/codesign', '--force', '--sign', '-']
    if name == 'vphone-vm':
        arguments += ['--entitlements', root / 'sources/vphone.entitlements']
    run(*arguments, target)
(bundle / 'Contents/Resources/api-proxy-fix-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
run(root / '.venv/bin/python3', '-B', root / 'scripts/build_native_dependencies.py', bundle)
run(root / '.venv/bin/python3', '-B', root / 'scripts/record_build_dependencies.py', bundle)
run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
run(root / '.venv/bin/python3', '-B', root / 'scripts/check_bundle.py', bundle, '--execute')


def inventory(directory):
    return {str(p.relative_to(directory)): digest(p) for p in directory.rglob('*') if p.is_file()}


before, after = inventory(baseline), inventory(bundle)
changed = [name for name in sorted(before.keys() | after.keys()) if before.get(name) != after.get(name)]
allowed = {'Contents/MacOS/vphone-cli', 'Contents/MacOS/vphone-vm', 'Contents/_CodeSignature/CodeResources',
    'Contents/Resources/build-dependencies.json', 'Contents/Resources/api-proxy-fix-provenance.json'}
assert set(changed) <= allowed, changed
vm_sha = digest(bundle / 'Contents/MacOS/vphone-vm')
version = '2.6.2-local.' + vm_sha[:12]
archive = work / (version + '.tar')
assert not archive.exists()
run('/usr/bin/tar', '-cf', archive, '-C', bundle.parent, 'VPhone.bundle')
cdhashes = {}
for name in ('vphone-cli', 'vphone-vm'):
    text = subprocess.check_output(['/usr/bin/codesign', '-d', '--verbose=4', str(bundle / 'Contents/MacOS' / name)],
                                    text=True, stderr=subprocess.STDOUT)
    cdhashes[name] = next(line.split('=', 1)[1] for line in text.splitlines() if line.startswith('CDHash='))
record = dict(state='prepared_not_installed', sourceCommit=commit, baselineVersion='2.6.2-local.af333c78ac3b',
    version=version, archive=str(archive), archiveSHA256=digest(archive), archiveBytes=archive.stat().st_size,
    bundle=str(bundle), storeDestination='/Library/Application Support/vphone-launchpad/Bundles/' + version,
    cliSHA256=digest(bundle / 'Contents/MacOS/vphone-cli'), vmSHA256=vm_sha, cdhashes=cdhashes,
    changedPaths=changed, guestResourcesUnchanged=True, frameworkLibrariesUnchanged=True,
    sourceSnapshotVerified=True, sourceFiles=len(provenance['workspaceSourceSHA256']),
    buildUsesExistingWorkingTree=True, VMStarted=False, AMFIChanged=False)
(work / 'candidate.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, indent=2))

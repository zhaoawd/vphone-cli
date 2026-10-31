#!/usr/bin/env python3
"""Package a host shutdown repair while preserving the accepted guest assets.

Run after release builds of vphone-cli and vphone-vm. This never installs a
Bundle, changes a VM binding, launches a VM, or starts an AMFI helper.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-real-20261021/gui-shutdown-fix'
base = root / '.build/t52-real-20261021/package/VPhone.bundle'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package-name', default='package')
parser.add_argument('--inspect-existing', action='store_true', help='Validate and record an already built candidate without rewriting it')
args = parser.parse_args()
if not args.package_name or Path(args.package_name).name != args.package_name:
    raise SystemExit('Package name must be one path component')
bundle = work / args.package_name / 'VPhone.bundle'
run = lambda *args: subprocess.run([str(arg) for arg in args], cwd=root, check=True)
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
if not args.inspect_existing:
    if bundle.exists():
        raise SystemExit('Preserve the existing candidate; choose a new path')
    work.mkdir(parents=True, exist_ok=True)
    bundle.parent.mkdir()
    run('/usr/bin/ditto', base, bundle)
    for name in ('vphone-cli', 'vphone-vm'):
        target = bundle / 'Contents/MacOS' / name
        shutil.copy2(root / '.build/release' / name, target)
        arguments = ['/usr/bin/codesign', '--force', '--sign', '-']
        if name == 'vphone-vm':
            arguments += ['--entitlements', str(root / 'sources/vphone.entitlements')]
        run(*arguments, target)
    sources = ['sources/vphone-cli/VPhoneAppDelegate.swift',
               'sources/VPhoneAPIKit/VPhoneAPIGuestShutdown.swift',
               'sources/VPhoneCore/VPhoneShutdownPolicy.swift',
               'tests/VPhoneCLITests/GuestShutdownTests.swift',
               'tests/VPhoneAPIKitTests/APIGuestShutdownTests.swift']
    provenance = dict(
        baseBundle='2.6.2-local.cd529f26a150',
        scope='Host-only direct VSOCK shutdown; no default host HTTP listener',
        guestAssets='Copied unchanged from the previously installed and verified candidate',
        head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        sourceSHA256={path: digest(root / path) for path in sources},
        releaseBuilds=['swift build --disable-sandbox --cache-path .build/test-cache -c release --force-resolved-versions --product ' + name
                       for name in ('vphone-cli', 'vphone-vm')])
    (bundle / 'Contents/Resources/host-shutdown-fix-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    run(root / '.venv/bin/python3', '-B', root / 'scripts/build_native_dependencies.py', bundle)
    run(root / '.venv/bin/python3', '-B', root / 'scripts/record_build_dependencies.py', bundle)
    run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
else:
    provenance = json.loads((bundle / 'Contents/Resources/host-shutdown-fix-provenance.json').read_text())
run(root / '.venv/bin/python3', '-B', root / 'scripts/check_bundle.py', bundle)

def inventory(directory):
    return {str(path.relative_to(directory)): digest(path) for path in directory.rglob('*') if path.is_file()}

before, after = inventory(base), inventory(bundle)
changes = [path for path in sorted(before.keys() | after.keys()) if before.get(path) != after.get(path)]
allowed = {'Contents/MacOS/vphone-cli', 'Contents/MacOS/vphone-vm', 'Contents/_CodeSignature/CodeResources',
           'Contents/Resources/build-dependencies.json', 'Contents/Resources/host-shutdown-fix-provenance.json'}
assert set(changes) <= allowed, changes
vm_sha = digest(bundle / 'Contents/MacOS/vphone-vm')
version = '2.6.2-local.' + vm_sha[:12]
archive = work / (version + '.tar')
if not args.inspect_existing:
    if archive.exists():
        raise SystemExit('Preserve the existing archive')
    run('/usr/bin/tar', '-cf', archive, '-C', bundle.parent, 'VPhone.bundle')
else:
    if not archive.is_file():
        raise SystemExit('Existing archive is required')
signatures = {}
for name in ('vphone-cli', 'vphone-vm'):
    output = subprocess.check_output(['/usr/bin/codesign', '-d', '--verbose=4', str(bundle / 'Contents/MacOS' / name)],
                                     stderr=subprocess.STDOUT, text=True)
    signatures[name] = next(line.split('=', 1)[1] for line in output.splitlines() if line.startswith('CDHash='))
record = dict(state='prepared_not_installed', version=version, archive=str(archive),
              archiveSHA256=digest(archive), archiveBytes=archive.stat().st_size,
              bundle=str(bundle), storeDestination='/Library/Application Support/vphone-launchpad/Bundles/' + version,
              cliSHA256=digest(bundle / 'Contents/MacOS/vphone-cli'), vmSHA256=vm_sha,
              signatures=signatures, changedPaths=changes, guestResourcesUnchanged=True,
              frameworkLibrariesUnchanged=True, provenance=provenance,
              realDefaultGUIAcceptance='not_run', AMFI='not_started', installed=False)
(work / 'candidate.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, indent=2))

#!/usr/bin/env python3
"""Package the EXP plist staging lifetime repair over the preserved 3ffd candidate."""
import json
from pathlib import Path
import shutil
import subprocess

from build_t33_cryptex_links_candidate import ROOT, WORK, sha, inventory
from patchers.component_signatures import verify_signing, entitlements

PACKAGE = WORK / 'exp-plist-lifetime-package-20261025'
RECORD = WORK / 'candidate-exp-plist-lifetime-20261025.json'
SOURCES = ('scripts/cfw_install_exp.sh',)


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    old = json.loads((WORK / 'candidate-exp-bootstrap-20261025.json').read_bytes())
    if old['version'] != '2.6.2-local.3ffd9e46ee74' or sha(old['archive']) != old['archiveSHA256']:
        raise ValueError('Preserved candidate differs')
    if PACKAGE.exists() or RECORD.exists():
        raise ValueError('Preserve existing candidate output')
    pristine = WORK / 'exp-plist-lifetime-pristine-3ffd-20261025'
    pristine.mkdir()
    run('/usr/bin/tar', '-xf', old['archive'], '-C', pristine)
    base = pristine / 'VPhone.bundle'
    run(ROOT / '.venv/bin/python', ROOT / 'scripts/check_bundle.py', base)
    before = inventory(base); PACKAGE.mkdir(); bundle = PACKAGE / 'VPhone.bundle'
    run('/usr/bin/ditto', base, bundle)
    for relative in SOURCES:
        shutil.copy2(ROOT / relative, bundle / 'Contents/Resources' / relative)
    provenance = bundle / 'Contents/Resources/t32-producer-provenance.json'
    record = json.loads(provenance.read_bytes())
    for relative in SOURCES:
        record['sourceSHA256'][relative] = sha(ROOT / relative)
    record['expPlistStagingLifetimeRepair'] = dict(baseVersion=old['version'],
        baseArchiveSHA256=old['archiveSHA256'], installed=False, runtimeValidated=False,
        scope='use a separate EXP plist staging path after base temporary-directory cleanup; target table and integrity verifiers unchanged')
    provenance.write_text(json.dumps(record, indent=2) + '\n')
    run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
    run(ROOT / '.venv/bin/python', ROOT / 'scripts/record_build_dependencies.py', bundle)
    run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
    run(ROOT / '.venv/bin/python', ROOT / 'scripts/check_bundle.py', bundle)
    after = inventory(bundle)
    changed = sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))
    allowed = {'Contents/Resources/' + path for path in SOURCES} | {
        'Contents/Resources/t32-producer-provenance.json', 'Contents/Resources/build-dependencies.json',
        'Contents/_CodeSignature/CodeResources', 'Contents/MacOS/vphone-cli'}
    if set(changed) - allowed:
        raise ValueError('Unexpected package changes: ' + str(set(changed) - allowed))
    cli = bundle / 'Contents/MacOS/vphone-cli'
    verify_signing(base / 'Contents/MacOS/vphone-cli', cli)
    if entitlements(base / 'Contents/MacOS/vphone-cli') != entitlements(cli):
        raise ValueError('CLI entitlements changed')
    if sha(bundle / 'Contents/MacOS/vphone-vm') != old['vmSHA256']:
        raise ValueError('VM executable changed')
    version = '2.6.2-local.' + sha(bundle / 'Contents/Resources/build-dependencies.json')[:12]
    archive = WORK / (version + '.tar')
    if archive.exists():
        raise ValueError('Preserve existing archive')
    run('/usr/bin/tar', '-cf', archive, '-C', PACKAGE, 'VPhone.bundle')
    value = dict(state='prepared_not_installed', version=version, bundle=str(bundle), archive=str(archive),
        archiveSHA256=sha(archive), archiveBytes=archive.stat().st_size, cliSHA256=sha(cli),
        vmSHA256=old['vmSHA256'], changedPaths=changed, cliExecutableContentUnchanged=True,
        vmExecutableUnchanged=True, guestAssetsUnchanged=True,
        targetRulesSHA256=old['targetRulesSHA256'], runtimeValidated=False,
        baseVersion=old['version'], baseArchiveSHA256=old['archiveSHA256'])
    with RECORD.open('x') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')
    print(json.dumps(value))


if __name__ == '__main__':
    main()

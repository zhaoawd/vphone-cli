#!/usr/bin/env python3
"""Prepare the repaired EXP producer and matching CLI; never install or boot."""
import json
from pathlib import Path
import shutil
import subprocess

from build_t33_cryptex_links_candidate import ROOT, WORK, sha, inventory

PACKAGE = WORK / 'exp-target-binding-package-20261025'
RECORD = WORK / 'candidate-exp-target-binding-20261025.json'
SOURCES = ('scripts/patchers/cfw.py', 'scripts/patchers/guest_write.py',
           'scripts/patchers/guest-targets.json', 'scripts/cfw_install_exp.sh')


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    old = json.loads((WORK / 'candidate-exp-cryptex-links-package-20261024-r3.json').read_bytes())
    base = Path(old['bundle'])
    if old['version'] != '2.6.2-local.16f1cc296c84' or sha(Path(old['archive'])) != old['archiveSHA256']:
        raise ValueError('Preserved base candidate differs')
    if PACKAGE.exists() or RECORD.exists():
        raise ValueError('Preserve existing candidate output')
    run(ROOT / '.venv/bin/python', ROOT / 'scripts/generate_guest_target_rules.py', '--check')
    run(ROOT / '.venv/bin/python', ROOT / 'scripts/check_bundle.py', base)
    before = inventory(base)
    PACKAGE.mkdir()
    bundle = PACKAGE / 'VPhone.bundle'
    run('/usr/bin/ditto', base, bundle)
    cli = bundle / 'Contents/MacOS/vphone-cli'
    shutil.copy2(ROOT / '.build/release/vphone-cli', cli)
    run('/usr/bin/codesign', '--force', '--sign', '-', cli)
    for relative in SOURCES:
        shutil.copy2(ROOT / relative, bundle / 'Contents/Resources' / relative)
    provenance = bundle / 'Contents/Resources/t32-producer-provenance.json'
    report = json.loads(provenance.read_bytes())
    compiled = sorted((ROOT / 'sources').rglob('*.swift'))
    for path in compiled + [ROOT / p for p in (*SOURCES, 'Package.swift', 'Package.resolved')]:
        report['sourceSHA256'][str(path.relative_to(ROOT))] = sha(path)
    report['targetBindingRepair'] = dict(baseVersion=old['version'], baseArchiveSHA256=old['archiveSHA256'],
        targetRulesSHA256=sha(ROOT / 'scripts/patchers/guest-targets.json'), cliRebuilt=True,
        vmReused=True, guestAssetsReused=True, installed=False, runtimeValidated=False,
        scope='transaction-qualified staged target binding and exact System/Cryptexes plist target')
    provenance.write_text(json.dumps(report, indent=2) + '\n')
    run(ROOT / '.venv/bin/python', ROOT / 'scripts/build_native_dependencies.py', bundle)
    run(ROOT / '.venv/bin/python', ROOT / 'scripts/record_build_dependencies.py', bundle)
    run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
    run(ROOT / '.venv/bin/python', ROOT / 'scripts/check_bundle.py', bundle)
    after = inventory(bundle)
    changed = sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))
    allowed = {'Contents/Resources/' + p for p in SOURCES} | {
        'Contents/MacOS/vphone-cli', 'Contents/Resources/t32-producer-provenance.json',
        'Contents/Resources/build-dependencies.json', 'Contents/_CodeSignature/CodeResources'}
    if set(changed) - allowed:
        raise ValueError('Unexpected candidate changes: ' + str(set(changed) - allowed))
    if sha(bundle / 'Contents/MacOS/vphone-vm') != old['vmSHA256']:
        raise ValueError('VM executable changed')
    version = '2.6.2-local.' + sha(bundle / 'Contents/Resources/build-dependencies.json')[:12]
    archive = WORK / (version + '.tar')
    if archive.exists():
        raise ValueError('Preserve existing candidate archive')
    run('/usr/bin/tar', '-cf', archive, '-C', PACKAGE, 'VPhone.bundle')
    result = dict(state='prepared_not_installed', version=version, bundle=str(bundle), archive=str(archive),
        archiveSHA256=sha(archive), archiveBytes=archive.stat().st_size, cliSHA256=sha(cli),
        vmSHA256=old['vmSHA256'], changedPaths=changed, cliRebuilt=True,
        vmExecutableUnchanged=True, guestAssetsUnchanged=True,
        targetRulesSHA256=sha(ROOT / 'scripts/patchers/guest-targets.json'), runtimeValidated=False,
        baseVersion=old['version'], baseArchiveSHA256=old['archiveSHA256'])
    with RECORD.open('x') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()

"""Package source-observation continuity over 73b without rebuilding host code."""
import json
from pathlib import Path
import shutil
import subprocess

from build_t33_cryptex_links_candidate import ROOT, WORK, sha, inventory
from patchers.component_signatures import verify_signing, entitlements

PACKAGE = WORK / 'exp-source-identity-package-20261026'
RECORD = WORK / 'candidate-exp-source-identity-20261026.json'
SOURCES = ('scripts/cfw_source_identity.py', 'scripts/patchers/undo_provenance.py',
           'scripts/patchers/file_originals.py', 'scripts/check_bundle.py')


def run(*args):
    value = subprocess.run([str(arg) for arg in args], cwd=ROOT, capture_output=True)
    if value.returncode: raise RuntimeError(value.stderr.decode(errors='replace'))
    return value


def main():
    old = json.loads((WORK / 'candidate-exp-reboot-recovery-20261026.json').read_bytes())
    if old['version'] != '2.6.2-local.73b536cbb70c' or sha(old['archive']) != old['archiveSHA256']:
        raise ValueError('Preserved 73b candidate differs')
    pristine = WORK / 'source-identity-pristine-73b-20261026'
    if any(p.exists() for p in (PACKAGE, RECORD, pristine)):
        raise ValueError('Preserve existing package preparation')
    pristine.mkdir(); run('/usr/bin/tar', '-xf', old['archive'], '-C', pristine)
    base = pristine / 'VPhone.bundle'; run('/usr/bin/codesign', '--verify', '--deep', '--strict', base)
    before = inventory(base); PACKAGE.mkdir(); bundle = PACKAGE / 'VPhone.bundle'; run('/usr/bin/ditto', base, bundle)
    for relative in SOURCES: shutil.copy2(ROOT / relative, bundle / 'Contents/Resources' / relative)
    provenance = bundle / 'Contents/Resources/t32-producer-provenance.json'; report = json.loads(provenance.read_bytes())
    for relative in SOURCES: report['sourceSHA256'][relative] = sha(ROOT / relative)
    report['generationSourceIdentityRepair'] = dict(baseVersion=old['version'], baseArchiveSHA256=old['archiveSHA256'],
        scope='explicit root registration of named manifest-qualified generation source observations; only recorded device may differ; historical timestamps are not invented',
        guestAssetsUnchanged=True, installed=False, runtimeValidated=False)
    provenance.write_text(json.dumps(report, indent=2) + '\n')
    run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/record_build_dependencies.py', bundle)
    run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
    print(run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/check_bundle.py', bundle).stdout.decode(), end='')
    after = inventory(bundle)
    changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
    allowed = {'Contents/Resources/' + p for p in SOURCES} | {'Contents/Resources/t32-producer-provenance.json',
        'Contents/Resources/build-dependencies.json', 'Contents/_CodeSignature/CodeResources', 'Contents/MacOS/vphone-cli'}
    if set(changed) - allowed: raise ValueError('Unexpected candidate changes: ' + str(set(changed) - allowed))
    cli = bundle / 'Contents/MacOS/vphone-cli'; vm = bundle / 'Contents/MacOS/vphone-vm'
    verify_signing(base / 'Contents/MacOS/vphone-cli', cli)
    if entitlements(base / 'Contents/MacOS/vphone-cli') != entitlements(cli) or sha(vm) != old['vmSHA256']:
        raise ValueError('Host executable content or entitlements changed')
    version = '2.6.2-local.' + sha(bundle / 'Contents/Resources/build-dependencies.json')[:12]
    archive = WORK / (version + '.tar')
    if archive.exists(): raise ValueError('Preserve existing archive')
    run('/usr/bin/tar', '-cf', archive, '-C', PACKAGE, 'VPhone.bundle')
    value = dict(state='prepared_not_installed', version=version, bundle=str(bundle), archive=str(archive),
        archiveSHA256=sha(archive), archiveBytes=archive.stat().st_size, cliSHA256=sha(cli),
        vmSHA256=old['vmSHA256'], vmCDHash=old['vmCDHash'], targetRulesSHA256=old['targetRulesSHA256'],
        changedPaths=changed, cliExecutableContentUnchanged=True, vmExecutableUnchanged=True,
        guestAssetsUnchanged=True, runtimeValidated=False, baseVersion=old['version'], baseArchiveSHA256=old['archiveSHA256'])
    with RECORD.open('x') as output: output.write(json.dumps(value, indent=2) + '\n')
    print(json.dumps(value))


if __name__ == '__main__':
    main()

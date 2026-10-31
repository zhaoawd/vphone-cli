"""Package reboot recovery over f430, preserving every guest payload."""
import json
from pathlib import Path
import shutil
import subprocess

from build_t33_cryptex_links_candidate import ROOT, WORK, sha, inventory
from patchers.component_signatures import entitlements
from build_native_dependencies import load_commands, system_library

PACKAGE = WORK / 'exp-reboot-recovery-package-20261026-r2'
RECORD = WORK / 'candidate-exp-reboot-recovery-20261026.json'
SOURCES = ('scripts/cfw_disk_txn.py', 'scripts/cfw_guest_evidence.py',
           'scripts/cfw_reboot_identity.py', 'scripts/patchers/guest_undo.py',
           'scripts/patchers/guest_recovery.py', 'scripts/check_bundle.py')
SWIFT = ('sources/FirmwarePatcher/Pipeline/FirmwareGuestDiskIdentity.swift',
         'sources/FirmwarePatcher/Pipeline/FirmwareRebootIdentity.swift')


def run(*args):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, capture_output=True)
    if result.returncode:
        raise RuntimeError('Command failed: ' + str(args[0]) + '\n' + result.stderr.decode(errors='replace'))
    return result


def main():
    old = json.loads((WORK / 'candidate-exp-plist-lifetime-20261025.json').read_bytes())
    if (old['version'] != '2.6.2-local.f43043c4c559'
            or old['archiveSHA256'] != 'ccab620462599a22502510ff29861df158252c8f8ce8733060015eea32d86c73'
            or sha(old['archive']) != old['archiveSHA256']):
        raise ValueError('Preserved f430 archive differs')
    pristine = WORK / 'exp-reboot-recovery-pristine-f430-20261026-r2'
    if any(p.exists() for p in (PACKAGE, RECORD, pristine)):
        raise ValueError('Preserve existing candidate output')
    pristine.mkdir(); run('/usr/bin/tar', '-xf', old['archive'], '-C', pristine)
    base = pristine / 'VPhone.bundle'; before = inventory(base)
    PACKAGE.mkdir(); bundle = PACKAGE / 'VPhone.bundle'; run('/usr/bin/ditto', base, bundle)
    provenance = bundle / 'Contents/Resources/t32-producer-provenance.json'
    report = json.loads(provenance.read_bytes())
    # The host rebuild must not incorporate unrelated Swift source changes.
    for relative, digest in report['sourceSHA256'].items():
        if relative.endswith('.swift') and relative not in SWIFT and sha(ROOT / relative) != digest:
            raise ValueError('Unreviewed Swift source change: ' + relative)
    for relative in SOURCES:
        shutil.copy2(ROOT / relative, bundle / 'Contents/Resources' / relative)
    for relative in (*SOURCES, *SWIFT):
        report['sourceSHA256'][relative] = sha(ROOT / relative)
    report['rebootRecoveryRepair'] = dict(baseVersion=old['version'], baseArchiveSHA256=old['archiveSHA256'],
        scope='explicit file identity registration and observed recovery of a preserved unsealed Undo; historical records unchanged',
        guestAssetsUnchanged=True, installed=False, runtimeValidated=False)
    provenance.write_text(json.dumps(report, indent=2) + '\n')
    for name in ('vphone-cli', 'vphone-vm'):
        path = bundle / 'Contents/MacOS' / name
        shutil.copy2(ROOT / '.build/out/Products/Release' / name, path)
        dependencies, rpaths, _ = load_commands(path)
        if any(not system_library(value) for value in dependencies):
            raise ValueError('Rebuilt host executable requires an unreviewed library')
        # The normal portable bundle staging removes toolchain/local rpaths.
        # Only the two newly built host executables need that adjustment here.
        for rpath in rpaths:
            if not system_library(rpath):
                run('/usr/bin/install_name_tool', '-delete_rpath', rpath, path)
        args = ['/usr/bin/codesign', '--force', '--sign', '-']
        if name == 'vphone-vm':
            args += ['--entitlements', ROOT / 'sources/vphone.entitlements']
        run(*args, path)
        if entitlements(base / 'Contents/MacOS' / name) != entitlements(path):
            raise ValueError('Host entitlements changed: ' + name)
        run('/usr/bin/codesign', '--verify', '--strict', path)
    run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/record_build_dependencies.py', bundle)
    run('/usr/bin/codesign', '--force', '--sign', '-', bundle)
    checked = run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/check_bundle.py', bundle)
    print(checked.stdout.decode(), end='')
    after = inventory(bundle)
    changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
    allowed = {'Contents/Resources/' + p for p in SOURCES} | {
        'Contents/MacOS/vphone-cli', 'Contents/MacOS/vphone-vm', 'Contents/_CodeSignature/CodeResources',
        'Contents/Resources/t32-producer-provenance.json', 'Contents/Resources/build-dependencies.json'}
    if set(changed) - allowed:
        raise ValueError('Unexpected package changes: ' + str(set(changed) - allowed))
    rules = bundle / 'Contents/Resources/scripts/patchers/guest-targets.json'
    if sha(rules) != old['targetRulesSHA256']:
        raise ValueError('Target rules changed')
    cli = bundle / 'Contents/MacOS/vphone-cli'; vm = bundle / 'Contents/MacOS/vphone-vm'
    cd = run('/usr/bin/codesign', '-d', '--verbose=4', vm).stderr.decode()
    cdhash, = [line.split('=', 1)[1] for line in cd.splitlines() if line.startswith('CDHash=')]
    version = '2.6.2-local.' + sha(bundle / 'Contents/Resources/build-dependencies.json')[:12]
    archive = WORK / (version + '.tar')
    if archive.exists():
        raise ValueError('Preserve existing archive')
    run('/usr/bin/tar', '-cf', archive, '-C', PACKAGE, 'VPhone.bundle')
    value = dict(state='prepared_not_installed', version=version, bundle=str(bundle), archive=str(archive),
        archiveSHA256=sha(archive), archiveBytes=archive.stat().st_size, cliSHA256=sha(cli),
        vmSHA256=sha(vm), vmCDHash=cdhash, changedPaths=changed, guestAssetsUnchanged=True,
        cliExecutableContentUnchanged=False, vmExecutableUnchanged=False,
        targetRulesSHA256=sha(rules), runtimeValidated=False,
        baseVersion=old['version'], baseArchiveSHA256=old['archiveSHA256'])
    with RECORD.open('x') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')
    print(json.dumps(value))


if __name__ == '__main__':
    main()

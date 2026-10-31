#!/usr/bin/env python3
"""Build and sign the remaining EXP resources on private local copies."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from patchers import component_signatures as signatures
from patchers.cfw_patch_watchdogd import patch_watchdogd
from patchers.guest_write import archive_targets


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--vm-input', type=Path, required=True)
    parser.add_argument('--guest-files', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(mode=0o700)
    scripts = args.bundle.resolve() / 'Contents/Resources/scripts'
    certificate = args.vm_input.resolve() / 'cfw_input/signcert.p12'
    cert_hash = sha(certificate)
    started = time.monotonic()
    result = dict(passed=False, VMStarts=0, securityWindows=0, nativeCFWExecuted=False,
                  scope='real retained resources; private copies; no APFS mounts', checks={})
    def run(argv, log, **kwargs):
        with (args.output / log).open('xb') as stream:
            subprocess.run([str(arg) for arg in argv], stdout=stream, stderr=subprocess.STDOUT,
                           check=True, timeout=120, **kwargs)
    try:
        # Execute the unchanged build functions from the actual candidate shell.
        text = (scripts / 'cfw_install_exp.sh').read_text()
        functions = text[text.index('ldid_sign_ent() {'):text.index('get_boot_manifest_hash() {')]
        setup = '''set -euo pipefail
die() { print -u2 -- "$*"; exit 1; }
cfw_guest_sign() { ldid "$@"; }
ldid_sign() { ldid -S "-K$VM_DIR/cfw_input/signcert.p12" "$1"; }
'''
        env = dict(os.environ, SCRIPT_DIR=str(scripts), TEMP_DIR=str(args.output.resolve()),
                   VM_DIR=str(args.vm_input.resolve()), CFW_INPUT='cfw_input')
        for function, name in [('build_tweakloader', 'TweakLoader.dylib'),
                               ('build_libvcamcaptured', 'libvcamcaptured.dylib'),
                               ('build_libcamfix', 'libcamfix.dylib')]:
            run(['/bin/zsh', '-c', setup + functions + '\n' + function], function + '.log', env=env)
            artifact = args.output / name
            signatures.verify_artifact(artifact, require_cms=True)
            result['checks'][name] = dict(passed=True, sha256=sha(artifact), cmsAndAllCodePages=True)
        for source in sorted((args.vm_input / 'cfw_jb_input/basebin').glob('*.dylib')):
            before_hash = sha(source)
            target = args.output / source.name
            shutil.copyfile(source, target)
            run(['ldid', '-S', '-K' + str(certificate), target], source.name + '.log')
            signatures.verify_signing(source, target)
            signatures.verify_artifact(target, require_cms=True)
            assert sha(source) == before_hash
            result['checks'][source.name] = dict(passed=True, sourceSHA256=before_hash, cmsAndAllCodePages=True)
        # Replay the actual debugserver entitlement change, without launching it.
        source = args.guest_files / 'debugserver'
        target = args.output / 'debugserver'
        shutil.copyfile(source, target)
        entitlements = plistlib.loads(subprocess.check_output(['ldid', '-e', str(source)]))
        entitlements.pop('seatbelt-profiles', None)
        entitlements['task_for_pid-allow'] = True
        ent = args.output / 'debugserver.entitlements'
        ent.write_bytes(plistlib.dumps(entitlements))
        run(['ldid', '-S' + str(ent), '-K' + str(certificate), target], 'debugserver.log')
        signatures.verify_signing(source, target)
        signatures.verify_artifact(target, require_cms=True)
        assert signatures.entitlements(target) == [entitlements]
        result['checks']['debugserver'] = dict(passed=True, cmsAndAllCodePages=True, neverLaunched=True)
        watchdog = args.output / 'watchdogd'
        shutil.copyfile(args.guest_files / 'watchdogd', watchdog)
        sites = patch_watchdogd(str(watchdog))
        assert sites > 0
        cds = signatures.directories(watchdog)
        signatures.verify_slots(watchdog, [dict(identity=c['identity'], slot=c['slot'], pages=range(c['count'])) for c in cds])
        result['checks']['watchdogd'] = dict(passed=True, patchedSites=sites, allCodePages=True,
            cmsScope='not re-signed; CMS integrity is not asserted')
        archive = args.vm_input / 'cfw_jb_input/jb/bootstrap-iphoneos-arm64.tar.zst'
        run(['/usr/bin/tar', '-tf', archive], 'bootstrap-members.txt')
        members = (args.output / 'bootstrap-members.txt').read_text().splitlines()
        assert any(PurePosixPath(path).parts == ('var',) for path in members), 'bootstrap lacks var directory'
        result['checks']['bootstrap'] = dict(passed=True, members=len(members), sha256=sha(archive),
            scope='archive listing; native extraction and ownership still pending')
        raw_archive = args.output / 'bootstrap-iphoneos-arm64.tar'
        with raw_archive.open('xb') as stream:
            subprocess.run(['zstd', '-d', '-c', str(archive)], stdout=stream, check=True, timeout=120)
        targets = archive_targets(raw_archive, args.output / 'bootstrap-targets')
        result['checks']['bootstrap']['exactMemberGatePassed'] = True
        result['checks']['bootstrap']['validatedTargets'] = len(targets)
        result['passed'] = True
    except Exception as error:
        result['error'] = str(error)
    assert sha(certificate) == cert_hash
    result['elapsedSeconds'] = time.monotonic() - started
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

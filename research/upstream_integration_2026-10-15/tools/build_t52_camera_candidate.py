#!/usr/bin/env python3
"""Seal the T52 camera candidate without installing or touching any VM."""
import hashlib
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-camera-interface-20261022'
BASE = ROOT / '.build/t52-api-proxy-deploy-20261022/package/VPhone.bundle'
BASE_VERSION = '2.6.2-local.266810c8ae29'
BUNDLE = WORK / 'package/VPhone.bundle'
sys.path.insert(0, str(ROOT / 'scripts'))
import check_guest_components


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resume-package', action='store_true')
    args = parser.parse_args()
    if BUNDLE.exists() and not args.resume_package:
        raise RuntimeError('Preserve the existing candidate')
    if not args.resume_package:
        BUNDLE.parent.mkdir()
        run('/usr/bin/ditto', BASE, BUNDLE)
    resources = BUNDLE / 'Contents/Resources'
    stage = resources / '.build/guest-components-v2/stage'
    for relative in ['camfix/libcamfix.dylib', 'vcamcaptured/libvcamcaptured.dylib']:
        shutil.copy2(WORK / 'siblings/stage' / relative, stage / relative)
    pins = json.loads((ROOT / 'dependencies/guest-components-pins.json').read_text())
    report = check_guest_components.inspect(stage, pins)
    (stage / 'manifest.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    # The general package retains the classic default. Its v2 installer records
    # VPHONED_CAMERA_LAYOUT=v2 in the explicit v2 launchd job.
    shutil.copy2(WORK / 'vphoned-classic', resources / 'guest-resources/vphoned')
    for relative in ['scripts/patchers/cfw.py', 'scripts/patchers/cfw_daemons.py',
                     'scripts/check_guest_components.py', 'dependencies/guest-components-pins.json']:
        shutil.copy2(ROOT / relative, resources / relative)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/check_guest_payloads.py',
        resources / 'guest-resources', '--record')
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/check_guest_api.py',
        resources / 'guest-resources', '--record')
    files = ['scripts/vphoned/vphoned_vcam.h', 'scripts/vphoned/vphoned_vcam.m',
             'sources/VPhoneGuestComponents/Shared/VPhoneCameraFrame.h',
             'sources/VPhoneGuestComponents/VCamCaptured/VCamFrameProtocol.h',
             'sources/VPhoneGuestComponents/VCamCaptured/VCamFrameReceiver.inc',
             'sources/VPhoneGuestComponents/VCamCaptured/libvcamcaptured.m',
             'sources/VPhoneGuestComponents/CamFix/libcamfix.m',
             'sources/VPhoneGuestComponents/CamFix/CameraMetadataOutput.inc',
             'scripts/patchers/cfw.py', 'scripts/patchers/cfw_daemons.py']
    provenance = dict(baseVersion=BASE_VERSION,
                      sourceSHA256={f: sha(ROOT / f) for f in files},
                      changedGuestLibraries=['libcamfix.dylib', 'libvcamcaptured.dylib'],
                      classicDefault='classic', v2LaunchdEnvironment={'VPHONED_CAMERA_LAYOUT': 'v2'},
                      acceptancePublisherDefault='v2', acceptancePublisherSHA256=sha(WORK / 'vphoned-v2'),
                      installed=False, runtimeValidated=False)
    (resources / 'camera-interface-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    run('/usr/bin/codesign', '--force', '--sign', '-', BUNDLE)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/record_build_dependencies.py', BUNDLE)
    run('/usr/bin/codesign', '--force', '--sign', '-', BUNDLE)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/check_bundle.py', BUNDLE)
    version = '2.6.2-local.' + sha(resources / 'build-dependencies.json')[:12]
    archive = WORK / (version + '.tar')
    run('/usr/bin/tar', '-cf', archive, '-C', BUNDLE.parent, 'VPhone.bundle')
    assert sha(BUNDLE / 'Contents/MacOS/vphone-vm') == sha(BASE / 'Contents/MacOS/vphone-vm')
    # The outer resource seal changes the main CLI signature; the VM executable
    # and its authorized CDHash remain byte-identical.
    before = {str(p.relative_to(BASE)): sha(p) for p in BASE.rglob('*') if p.is_file()}
    after = {str(p.relative_to(BUNDLE)): sha(p) for p in BUNDLE.rglob('*') if p.is_file()}
    result = dict(state='prepared_not_installed', version=version, bundle=str(BUNDLE), archive=str(archive),
                  archiveSHA256=sha(archive), archiveBytes=archive.stat().st_size,
                  hostVMUnchanged=True, hostVMCDHash='89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541',
                  APIUnchanged=True, frameworkLibrariesUnchanged=True,
                  v2Publisher=str(WORK / 'vphoned-v2'), v2PublisherSHA256=sha(WORK / 'vphoned-v2'),
                  changedPaths=[p for p in sorted(before.keys() | after.keys()) if before.get(p) != after.get(p)],
                  provenance=provenance)
    (WORK / 'candidate.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

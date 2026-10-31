#!/usr/bin/env python3
"""Seal a functional T52 candidate; no installation or VM operation."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-consumer-fix-20261022'
BASE = ROOT / '.build/t52-camera-diagnostics-20261022/package/VPhone.bundle'
BUNDLE = WORK / 'package/VPhone.bundle'
PUBLISHER_CLASSIC = WORK / 'vphoned-classic'
PUBLISHER_V2 = WORK / 'vphoned-v2'
sys.path.insert(0, str(ROOT / 'scripts'))
import check_guest_components


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def main():
    if BUNDLE.exists():
        raise ValueError('Preserve the existing sealed candidate')
    BUNDLE.parent.mkdir()
    run('/usr/bin/ditto', BASE, BUNDLE)
    resources = BUNDLE / 'Contents/Resources'
    stage = resources / '.build/guest-components-v2/stage'
    changed = ['camfix/libcamfix.dylib', 'locationfix/libvlocation.dylib',
               'launchhook/launchdhook-vphone.dylib', 'systemhook/SystemHook-vphone.dylib',
               'vcamcaptured/libvcamcaptured.dylib']
    for name in changed:
        shutil.copy2(WORK / 'siblings/stage' / name, stage / name)
    pins = json.loads((ROOT / 'dependencies/guest-components-pins.json').read_text())
    check_guest_components.check_sources(pins)
    report = check_guest_components.inspect(stage, pins)
    (stage / 'manifest.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    shutil.copy2(PUBLISHER_CLASSIC, resources / 'guest-resources/vphoned')
    for name in ['scripts/patchers/cfw_daemons.py', 'dependencies/guest-components-pins.json']:
        shutil.copy2(ROOT / name, resources / name)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/check_guest_payloads.py',
        resources / 'guest-resources', '--record')
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/check_guest_api.py',
        resources / 'guest-resources', '--stage-api', WORK / 'daemon-api/candidate', '--record')
    # Explicit v2 creation uses a different plist; the signed binary is identical.
    v2_api = resources / '.build/daemon-api-v2/candidate-v2'
    v2_api.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(WORK / 'daemon-api/candidate-v2', v2_api)
    assert sha(v2_api / 'vphoned') == sha(resources / 'guest-resources/api/vphoned')
    files = ['scripts/vphoned/Makefile', 'scripts/vphoned/vphoned_location.m',
             'scripts/vphoned/vphoned_location_bridge.inc', 'scripts/vphoned/vphoned_vcam.m',
             'scripts/patchers/cfw_daemons.py', 'sources/VPhoneDaemon/Daemon/GuestLocationSimulation.swift',
             'dependencies/guest-components-pins.json', 'dependencies/daemon-api-pins.json']
    files += [entry['local'] for entry in pins['files']]
    provenance = dict(baseVersion='2.6.2-local.56be1ce20ded',
        sourceSHA256={name: sha(ROOT / name) for name in sorted(set(files))},
        changedGuestLibraries=[Path(name).name for name in changed],
        classicDefault={'camera': 'classic', 'location': 'native'},
        v2LaunchdEnvironment={'VPHONED_CAMERA_LAYOUT': 'v2', 'VPHONED_LOCATION_LAYOUT': 'v2'},
        acceptancePublisherSHA256=sha(PUBLISHER_V2),
        APISHA256=sha(v2_api / 'vphoned'), installed=False, runtimeValidated=False)
    (resources / 'consumer-interface-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    run('/usr/bin/codesign', '--force', '--sign', '-', BUNDLE)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/record_build_dependencies.py', BUNDLE)
    run('/usr/bin/codesign', '--force', '--sign', '-', BUNDLE)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/check_bundle.py', BUNDLE)
    version = '2.6.2-local.' + sha(resources / 'build-dependencies.json')[:12]
    archive = WORK / (version + '.tar')
    run('/usr/bin/tar', '-cf', archive, '-C', BUNDLE.parent, 'VPhone.bundle')
    assert sha(BUNDLE / 'Contents/MacOS/vphone-vm') == sha(BASE / 'Contents/MacOS/vphone-vm')
    for name in ['lib/VPhoneCore.dylib', 'lib/VPhoneBundleStore.dylib']:
        if (BASE / 'Contents/Frameworks' / name).exists():
            assert sha(BASE / 'Contents/Frameworks' / name) == sha(BUNDLE / 'Contents/Frameworks' / name)
    before = {str(p.relative_to(BASE)): sha(p) for p in BASE.rglob('*') if p.is_file()}
    after = {str(p.relative_to(BUNDLE)): sha(p) for p in BUNDLE.rglob('*') if p.is_file()}
    result = dict(state='prepared_not_installed', version=version, bundle=str(BUNDLE),
        archive=str(archive), archiveSHA256=sha(archive), archiveBytes=archive.stat().st_size,
        hostVMUnchanged=True, hostVMCDHash='89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541',
        libraries={Path(name).name: sha(stage / name) for name in changed},
        v2Publisher=str(PUBLISHER_V2), v2PublisherSHA256=sha(PUBLISHER_V2),
        API=str(v2_api / 'vphoned'), APISHA256=sha(v2_api / 'vphoned'),
        changedPaths=[p for p in sorted(before.keys() | after.keys()) if before.get(p) != after.get(p)],
        provenance=provenance)
    (WORK / 'candidate.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ['state', 'version', 'archiveSHA256', 'libraries', 'APISHA256']}, indent=2))


if __name__ == '__main__': main()

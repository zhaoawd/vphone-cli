#!/usr/bin/env python3
"""Build fixed-source T53 experiments without installing or activating them.

An isolated library build does not establish production integration, migration
eligibility, or Xcode/DeviceHub/Flutter behavior. No VM is opened by this tool.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
TARGET = '2a0d3aca9fb79344d939365cc337b915ae9f2f97'
FILES = (
    'LICENSE',
    'VPhoneGuestComponents/DeviceHubFix/libdevicehubfix.c',
    'VPhoneGuestComponents/FlutterRemapFix/FlutterRemapPolicy.h',
    'VPhoneGuestComponents/FlutterRemapFix/libflutterremapfix.c',
    'VPhoneGuestComponents/LaunchHook/InstallCoordinationPersona.h',
    'VPhoneGuestComponents/Tests/InstallCoordinationPersonaTests.c',
    'VPhoneGuestComponents/Tests/FlutterRemapPolicyTests.c',
    'VPhoneGuestComponents/Tests/FlutterRemapRepairTests.c',
    'VPhoneGuestComponents/Makefile',
    'VPhoneGuestComponents/Shared/InjectionEnvironment.h',
    'VPhoneGuestComponents/Shared/AttitudeProcess.h',
    'VPhoneGuestComponents/Shared/JetsamLimits.h',
    'VPhoneGuestComponents/Shared/RootHideLoaderLinks.c',
    'VPhoneGuestComponents/Shared/RootHideLoaderLinks.h',
    'VPhoneGuestComponents/Shared/VPhoneX1Spawn.c',
    'VPhoneGuestComponents/Shared/VPhoneX1Spawn.h',
    'VPhoneGuestComponents/SystemHook/SystemHook-vphone.c',
    'VPhoneGuestComponents/LaunchHook/launchdhook-vphone.c',
    'VPhoneExecutable/VPhoneVirtualization/Build/StageBundle.sh',
    'VPhoneExecutable/VPhoneVirtualization/Build/ValidateBundle.sh',
    'VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwareGuestSystemPatchSet.swift',
    'Research/Guest/ios27_xcode_persona_lookup.md',
    'Research/Guest/flutter_aot_remap_compatibility.md',
)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify_product_metadata(work, stem):
    architecture = (work / (stem + '-architecture.log')).read_text().strip()
    fields = [line.split() for line in (work / (stem + '-platform.log')).read_text().splitlines()]
    if architecture != 'arm64e' or ['platform', 'IOS'] not in fields or ['minos', '26.0'] not in fields:
        raise ValueError('Unexpected candidate architecture/platform/deployment target: ' + stem)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='New directory beneath this repository; never overwritten')
    args = parser.parse_args()
    work = args.output.absolute()
    # resolve parent before mkdir so an external symlink cannot redirect writes.
    if not work.parent.is_dir() or ROOT not in work.parent.resolve().parents:
        parser.error('output parent must exist beneath the repository')
    work.mkdir(exist_ok=False)
    state = dict(upstreamTarget=TARGET, startedAt=time.time(), state='preparing',
                 VMStarted=False, guestInstalled=False, productIntegrated=False,
                 runtimeValidated=False, accepted=False, files={}, steps=[])

    def save():
        (work / 'result.json').write_text(json.dumps(state, indent=2) + '\n')

    def run(label, command):
        with (work / (label + '.log')).open('w') as log:
            completed = subprocess.run(command, cwd=ROOT, stdout=log,
                                       stderr=subprocess.STDOUT, timeout=120)
        state['steps'].append(dict(label=label, command=command,
                                   exitCode=completed.returncode))
        save()
        return completed.returncode == 0

    save()
    try:
        for name in FILES:
            data = subprocess.check_output(['git', 'show', TARGET + ':' + name], cwd=ROOT)
            path = work / 'upstream' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            state['files'][name] = dict(sha256=sha(data), bytes=len(data),
                gitBlob=subprocess.check_output(['git', 'rev-parse', TARGET + ':' + name], cwd=ROOT, text=True).strip())
        components = work / 'upstream/VPhoneGuestComponents'
        products = work / 'products'
        products.mkdir()
        for harness in ('InstallCoordinationPersonaTests', 'FlutterRemapPolicyTests', 'FlutterRemapRepairTests'):
            flags = ['-Wno-unused-function'] if harness == 'FlutterRemapRepairTests' else []
            command = ['/usr/bin/xcrun', '--sdk', 'macosx', 'clang', '-Wall', '-Wextra', '-Werror',
                       *flags, '-o', str(products / harness), str(components / 'Tests' / (harness + '.c'))]
            if run(harness + '-build', command):
                run(harness + '-run', [str(products / harness)])
        flags = ['/usr/bin/xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64e',
                 '-miphoneos-version-min=26.0', '-Os', '-dynamiclib', '-Wl,-not_for_dyld_shared_cache']
        device = products / 'libdevicehubfix.dylib'
        run('devicehub-build', flags + ['-install_name', '/usr/lib/libdevicehubfix.dylib',
            '-o', str(device), str(components / 'DeviceHubFix/libdevicehubfix.c'),
            '-Wl,-U,_$s19CoreDeviceUtilities28MediaStreamSupportedFeaturesV7currentACvgZ',
            '-Wl,-U,_$s19CoreDeviceUtilities07CurrentB0V20isCustomerRestrictedSbvg',
            '-framework', 'CoreFoundation', '-framework', 'CoreVideo', '-framework', 'IOSurface',
            '-lMobileGestalt', '-lobjc'])
        flutter = products / 'libflutterremapfix.dylib'
        run('flutter-build', flags + ['-install_name', '/usr/lib/libflutterremapfix.dylib',
            '-o', str(flutter), str(components / 'FlutterRemapFix/libflutterremapfix.c')])
        system = products / 'SystemHook-vphone.dylib'
        system_sources = ('SystemHook/SystemHook-vphone.c', 'FlutterRemapFix/libflutterremapfix.c',
                          'Shared/RootHideLoaderLinks.c', 'Shared/VPhoneX1Spawn.c')
        run('systemhook-build', flags + ['-install_name', '/usr/lib/SystemHook-vphone.dylib',
            '-o', str(system), *(str(components / name) for name in system_sources)])
        state['products'] = {}
        for path in (device, flutter, system):
            if not path.is_file():
                continue
            if run(path.stem + '-sign', ['/usr/bin/codesign', '--force', '--sign', '-', str(path)]):
                run(path.stem + '-verify', ['/usr/bin/codesign', '--verify', '--strict', str(path)])
                run(path.stem + '-architecture', ['/usr/bin/lipo', '-archs', str(path)])
                run(path.stem + '-platform', ['/usr/bin/xcrun', 'vtool', '-show-build', str(path)])
                run(path.stem + '-imports', ['/usr/bin/otool', '-L', str(path)])
                verify_product_metadata(work, path.stem)
            state['products'][path.name] = dict(sha256=sha(path.read_bytes()), bytes=path.stat().st_size)
        failures = [step['label'] for step in state['steps'] if step['exitCode']]
        state.update(state='isolated_checks_failed' if failures else 'isolated_checks_passed',
                     failures=failures, finishedAt=time.time())
    except Exception as error:
        state.update(state='failed', error=f'{type(error).__name__}: {error}')
        raise
    finally:
        save()
    print(json.dumps(dict(state=state['state'], steps=len(state['steps']),
                         failures=state['failures'], runtimeValidated=False)))
    return 1 if state['failures'] else 0


if __name__ == '__main__':
    raise SystemExit(main())

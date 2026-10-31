#!/usr/bin/env python3
"""Validate the complete app and optionally run its signed resource probe outside the repo."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

REQUIRED = (
    'AppIcon.icns', 'build-dependencies.json', 'requirements.txt', 'debs.list', 'README.md',
    'scripts/fw_prepare.sh', 'scripts/ipsw_cache_entry.py',
    'scripts/cfw_install_host.sh', 'scripts/cfw_disk_txn.py', 'scripts/cfw_guest_evidence.py', 'scripts/sparse_file.py',
    'scripts/cfw_env_update.py', 'scripts/cfw_env_install.py', 'scripts/guest_environment.json',
    'scripts/cfw_install.sh', 'scripts/cfw_install_dev.sh',
    'scripts/cfw_install_jb.sh', 'scripts/cfw_install_exp.sh',
    'scripts/lib/cfw_common.sh',
    'scripts/licenses/libarchive.txt',
    'scripts/licenses/MobileRecoveryCore.txt', 'scripts/licenses/MobileRestoreCore.txt',
    'scripts/licenses/AppleMobileDeviceLibrary.txt', 'scripts/licenses/OpenSSL-SPM.txt',
    'scripts/licenses/AppleMobileDeviceLibrary-NOTICES.txt',
    'scripts/licenses/libimobiledevice-LGPL-2.1.txt',
    'scripts/licenses/OpenSSL.txt', 'scripts/licenses/GPL-3.0.txt',
    'scripts/boot_host_preflight.sh', 'scripts/pymobiledevice3_bridge.py',
    'scripts/check_python_runtime.py', 'scripts/python_environment.py', 'scripts/patchers/cfw.py',
    'scripts/patchers/guest_undo.py',
    'dependencies/python-darwin-arm64-3.13.lock', 'dependencies/python-darwin-arm64-3.14.lock',
    'dependencies/python-darwin-arm64-3.13.json', 'dependencies/python-darwin-arm64-3.14.json',
    'scripts/resources/cfw_input.tar.zst', 'scripts/resources/cfw_jb_input.tar.zst',
    'scripts/resources/cfw_dev/rpcserver_ios', 'scripts/vphoned/signcert.p12',
    'tools/apfs_snap_rename.py', '.tools/bin/trustcache', '.tools/bin/insert_dylib', '.tools/bin/zstd', '.tools/bin/xz',
    'scripts/licenses/LZ4.txt', 'scripts/licenses/zstd.txt', 'scripts/licenses/xz.txt', 'scripts/licenses/xz-0BSD.txt',
    'scripts/licenses/xz-GPLv2.txt', 'scripts/licenses/xz-LGPLv2.1.txt',
    'guest-resources/vphoned', 'guest-resources/vphoned-less',
    'guest-resources/vphoned.plist', 'guest-resources/vphoned.entitlements.plist',
    'guest-resources/manifest.json', 'vphone-amfidont',
    'guest-resources/cohort.json', 'guest-resources/api/vphoned',
    'guest-resources/api/vphoned.plist', 'guest-resources/api/vphoned.entitlements.plist',
    'guest-resources/api/manifest.json', 'scripts/check_guest_api.py',
    'scripts/check_guest_payloads.py', 'scripts/build_native_dependencies.py',
)


def check_resources(bundle):
    resources = bundle / 'Contents/Resources'
    for name in REQUIRED:
        path = resources / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing or empty bundle resource: {name}')
        if not path.resolve().is_relative_to(resources.resolve()):
            raise ValueError(f'Resource escapes the bundle: {name}')
    for name in ('vphone-cli', 'vphone-vm', 'ldid'):
        path = bundle / 'Contents/MacOS' / name
        if not path.is_file() or not os.access(path, os.X_OK) or not path.resolve().is_relative_to(bundle.resolve()):
            raise ValueError(f'Missing executable: {path}')
    for name in ('.tools/bin/zstd', '.tools/bin/xz', '.tools/bin/trustcache', '.tools/bin/insert_dylib', 'guest-resources/vphoned', 'guest-resources/vphoned-less', 'vphone-amfidont'):
        if not os.access(resources / name, os.X_OK):
            raise ValueError(f'Resource is not executable: {name}')
    return resources


def check_kernel_update_protocol(bundle):
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info.get('VPhoneKernelUpdateProtocol') != 'vphone.kernel-update.v1':
        raise ValueError('Bundle does not declare the stopped kernel update protocol')


def check_kernel_rollback_protocol(bundle):
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info.get('VPhoneKernelRollbackProtocol') != 'vphone.kernel-rollback.v1':
        raise ValueError('Bundle does not declare the committed kernel rollback protocol')


def check_environment_update_resources(bundle):
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    protocol = info.get('VPhoneEnvironmentUpdateProtocol')
    if protocol is None:
        return  # Older bundles remain valid for their existing operations.
    if protocol != 'vphone.environment-update.v1':
        raise ValueError('Unsupported environment update protocol')
    resources = bundle / 'Contents/Resources'
    stage = resources / '.build/guest-components-v2/stage'
    record = stage / 'manifest.json'
    if not record.is_file() or any(p.is_symlink() for p in (resources, resources / '.build', stage.parent, stage, record)):
        raise ValueError('Missing sealed environment component manifest')
    hashes = json.loads(record.read_text())['files_sha256']
    libraries = json.loads((resources / 'scripts/guest_environment.json').read_text())['libraries']
    for entry in libraries:
        relative = Path(entry['stage'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid environment component path')
        path = stage / relative
        ancestors = [p for p in path.parents if p == resources or resources in p.parents]
        if any(p.is_symlink() for p in (path, *ancestors)) or not path.is_file():
            raise ValueError('Missing or linked environment component: ' + str(relative))
        if hashlib.sha256(path.read_bytes()).hexdigest() != hashes.get(str(relative)):
            raise ValueError('Environment component digest mismatch: ' + str(relative))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--execute', action='store_true', help='Requires host authorization for private entitlements')
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    resources = check_resources(bundle)
    check_kernel_update_protocol(bundle)
    check_kernel_rollback_protocol(bundle)
    check_environment_update_resources(bundle)
    subprocess.run(['codesign', '--verify', '--strict', '--verbose=2', str(bundle)], check=True)
    subprocess.run([os.sys.executable, str(Path(__file__).resolve().parent / 'build_native_dependencies.py'),
                    str(bundle), '--check'], check=True)
    subprocess.run([os.sys.executable, str(resources / 'scripts/check_guest_payloads.py'),
                    str(resources / 'guest-resources'), '--ldid',
                    str(bundle / 'Contents/MacOS/ldid')], check=True)
    subprocess.run([os.sys.executable, '-B', str(resources / 'scripts/check_guest_api.py'),
                    str(resources / 'guest-resources'), '--ldid',
                    str(bundle / 'Contents/MacOS/ldid')], check=True)
    binary = bundle / 'Contents/MacOS/vphone-cli'
    expected = plistlib.loads((Path(__file__).resolve().parents[1] / 'sources/vphone.entitlements').read_bytes())
    for name in ('vphone-vm',):
        executable = bundle / 'Contents/MacOS' / name
        subprocess.run(['codesign', '--verify', '--strict', str(executable)], check=True)
        signed = subprocess.check_output(['codesign', '-d', '--entitlements', '-', '--xml', str(executable)])
        actual = plistlib.loads(signed)
        for key, value in expected.items():
            if actual.get(key) != value:
                raise ValueError(f'Incorrect signed entitlement in {name}: {key}')
    if args.execute:
        with tempfile.TemporaryDirectory(prefix='vphone-bundle-') as temp:
            link = Path(temp) / 'vphone-cli'
            link.symlink_to(binary)
            for executable in (binary, link):
                result = subprocess.check_output([str(executable), 'resources'], cwd=temp, text=True)
                if result.strip() != str(resources):
                    raise ValueError(f'Unexpected resource base: {result!r}')
        print('Signed resource resolution passed: external working directory and symlink')
    print('Complete bundle: resources, signature and entitlements verified')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Validate the complete app and optionally run its signed resource probe outside the repo."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

REQUIRED = (
    'AppIcon.icns', 'build-dependencies.json', 'requirements.txt', 'debs.list', 'README.md',
    'scripts/fw_prepare.sh', 'scripts/cfw_install_host.sh',
    'scripts/cfw_install.sh', 'scripts/cfw_install_dev.sh',
    'scripts/cfw_install_jb.sh', 'scripts/cfw_install_exp.sh',
    'scripts/lib/cfw_common.sh',
    'scripts/boot_host_preflight.sh', 'scripts/pymobiledevice3_bridge.py',
    'scripts/check_python_runtime.py', 'scripts/python_environment.py', 'scripts/patchers/cfw.py',
    'dependencies/python-darwin-arm64-3.13.lock', 'dependencies/python-darwin-arm64-3.14.lock',
    'dependencies/python-darwin-arm64-3.13.json', 'dependencies/python-darwin-arm64-3.14.json',
    'scripts/resources/cfw_input.tar.zst', 'scripts/resources/cfw_jb_input.tar.zst',
    'scripts/resources/cfw_dev/rpcserver_ios', 'scripts/vphoned/signcert.p12',
    'tools/apfs_snap_rename.py', '.tools/bin/trustcache', '.tools/bin/insert_dylib',
    'vphoned.signed', 'vphone-amfidont',
)


def check_resources(bundle):
    resources = bundle / 'Contents/Resources'
    for name in REQUIRED:
        path = resources / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing or empty bundle resource: {name}')
        if not path.resolve().is_relative_to(resources.resolve()):
            raise ValueError(f'Resource escapes the bundle: {name}')
    for name in ('vphone-cli', 'ldid'):
        path = bundle / 'Contents/MacOS' / name
        if not path.is_file() or not os.access(path, os.X_OK) or not path.resolve().is_relative_to(bundle.resolve()):
            raise ValueError(f'Missing executable: {path}')
    for name in ('.tools/bin/trustcache', '.tools/bin/insert_dylib', 'vphoned.signed', 'vphone-amfidont'):
        if not os.access(resources / name, os.X_OK):
            raise ValueError(f'Resource is not executable: {name}')
    return resources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--execute', action='store_true', help='Requires host authorization for private entitlements')
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    resources = check_resources(bundle)
    subprocess.run(['codesign', '--verify', '--strict', '--verbose=2', str(bundle)], check=True)
    binary = bundle / 'Contents/MacOS/vphone-cli'
    signed = subprocess.check_output(['codesign', '-d', '--entitlements', '-', '--xml', str(binary)])
    actual = plistlib.loads(signed)
    expected = plistlib.loads((Path(__file__).resolve().parents[1] / 'sources/vphone.entitlements').read_bytes())
    for key, value in expected.items():
        if actual.get(key) != value:
            raise ValueError(f'Incorrect signed entitlement: {key}')
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

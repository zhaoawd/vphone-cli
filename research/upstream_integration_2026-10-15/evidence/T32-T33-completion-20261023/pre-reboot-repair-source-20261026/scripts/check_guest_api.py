#!/usr/bin/env python3
"""核对默认独立 API 与 classic 组合；不执行或安装 iOS 映像。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

from check_guest_payloads import inspect as inspect_classic, output, validate_metadata
from daemon_api_overlays import declarations, validate_marker

ROOT = Path(__file__).resolve().parents[1]
API_FILES = ('vphoned', 'vphoned.plist', 'vphoned.entitlements.plist')
CACHE = '/var/root/Library/Caches/vphoned-api'
LABEL = 'com.vphone.vphoned-api'
PROGRAM = '/usr/libexec/vphoned-api'


def regular(path):
    if path.is_symlink() or not path.is_file() or not path.stat().st_size:
        raise ValueError(f'Missing regular API payload: {path}')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect_api(directory, ldid='ldid'):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('API directory must be a real directory')
    hashes = {name: regular(directory / name) for name in API_FILES}
    regular(directory / 'manifest.json')
    manifest = json.loads((directory / 'manifest.json').read_text())
    if hashes != manifest.get('files_sha256'):
        raise ValueError('API payload differs from its build manifest')
    pins = json.loads((ROOT / 'dependencies/daemon-api-pins.json').read_text())['pins']
    if manifest.get('pins') != pins:
        raise ValueError('API build pins differ from the fixed dependency graph')
    job = plistlib.loads((directory / 'vphoned.plist').read_bytes())
    if (job.get('Label') != LABEL or job.get('ProgramArguments') != [PROGRAM] or
            job.get('EnvironmentVariables') != {'VPHONE_DISABLE_CAMERA': '1'} or
            not job.get('RunAtLoad') or not job.get('KeepAlive')):
        raise ValueError('API job must use its own label/path and disable camera publishing')
    policy = plistlib.loads((directory / 'vphoned.entitlements.plist').read_bytes())
    if policy.get('com.apple.private.xpc.service-configure') is not True:
        raise ValueError('RootHide service-configure entitlement is required')
    image = directory / 'vphoned'
    if not os.access(image, os.X_OK):
        raise ValueError('API payload is not executable')
    contents = image.read_bytes()
    if (CACHE + '\0').encode() not in contents:
        raise ValueError('API payload does not use the separate cache namespace')
    validate_marker(contents, declarations())
    validate_metadata(output('/usr/bin/lipo', '-archs', str(image)),
                      output('/usr/bin/xcrun', 'vtool', '-show-build', str(image)),
                      output('/usr/bin/nm', '-u', str(image)),
                      plistlib.loads(subprocess.check_output([ldid, '-e', str(image)])), policy)
    return {'files_sha256': hashes, 'pins': pins, 'label': LABEL, 'program': PROGRAM,
            'cache': CACHE, 'api_port': 1339, 'camera_publisher_enabled': False,
            'bootstrap_startup_enabled': True, 'source_overlays': declarations()}


def inspect(directory, ldid='ldid'):
    classic = inspect_classic(directory, ldid)
    api = inspect_api(directory / 'api', ldid)
    job = plistlib.loads((directory / 'vphoned.plist').read_bytes())
    if job.get('Label') == api['label']:
        raise ValueError('Classic and API daemon labels must differ')
    return {'schema_version': 1, 'role': 'classic-control-camera-and-independent-api',
            'classic': {'files_sha256': classic['files_sha256'], 'control_port': 1337,
                        'camera_port': 1338, 'cache': '/var/root/Library/Caches/vphoned'},
            'api': api, 'runtime_validated': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--stage-api', type=Path)
    parser.add_argument('--record', action='store_true')
    parser.add_argument('--ldid', default='ldid')
    args = parser.parse_args()
    if args.stage_api:
        if not args.record:
            raise ValueError('Staging requires --record')
        inspect_api(args.stage_api, args.ldid)
        target = args.directory / 'api'
        if args.directory.is_symlink() or target.is_symlink():
            raise ValueError('Refusing symlink staging directory')
        target.mkdir(parents=True, exist_ok=True)
        for name in (*API_FILES, 'manifest.json'):
            if (target / name).is_symlink():
                raise ValueError('Refusing symlink staging file')
            shutil.copy2(args.stage_api / name, target / name)
    report = inspect(args.directory, args.ldid)
    record = args.directory / 'cohort.json'
    if record.is_symlink():
        raise ValueError('Refusing symlink cohort manifest')
    if args.record:
        record.write_text(json.dumps(report, indent=2) + '\n')
    elif json.loads(record.read_text()) != report:
        raise ValueError('Guest cohort manifest mismatch')
    print('Default classic control/camera and independent pinned API verified; runtime not validated')


if __name__ == '__main__':
    main()

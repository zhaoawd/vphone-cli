#!/usr/bin/env python3
"""Inspect pre-signed guest artifacts at build time; never execute iOS binaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

PAYLOADS = ('vphoned', 'vphoned-less')
FILES = (*PAYLOADS, 'vphoned.plist', 'vphoned.entitlements.plist')


def validate_metadata(architectures, build, symbols, entitlements, expected):
    if architectures.split() != ['arm64']:
        raise ValueError('Guest daemon must contain exactly the arm64 architecture')
    platforms = re.findall(r'^\s*platform\s+(\S+)', build, re.MULTILINE)
    versions = re.findall(r'^\s*minos\s+(\S+)', build, re.MULTILINE)
    if platforms != ['IOS'] or versions != ['15.0']:
        raise ValueError('Guest daemon must target IOS with deployment target 15.0')
    if re.search(r'\b_swift_initBorrow\b', symbols):
        raise ValueError('Guest daemon references unavailable _swift_initBorrow')
    if not isinstance(expected, dict) or not expected or entitlements != expected:
        raise ValueError('Guest daemon entitlements differ from the build policy')


def output(*args):
    return subprocess.check_output(args, text=True)


def inspect(directory, ldid='ldid'):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f'Guest directory must be a real directory: {directory}')
    digests = {}
    for name in FILES:
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing regular guest artifact: {path}')
        digests[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    expected = plistlib.loads((directory / 'vphoned.entitlements.plist').read_bytes())
    launchd = plistlib.loads((directory / 'vphoned.plist').read_bytes())
    if launchd.get('ProgramArguments', [None])[0] != '/usr/bin/vphoned':
        raise ValueError('Unexpected guest launchd executable')
    for name in PAYLOADS:
        path = directory / name
        if not os.access(path, os.X_OK):
            raise ValueError(f'Guest daemon is not executable: {path}')
        validate_metadata(
            output('/usr/bin/lipo', '-archs', str(path)),
            output('/usr/bin/xcrun', 'vtool', '-show-build', str(path)),
            output('/usr/bin/nm', '-u', str(path)),
            plistlib.loads(subprocess.check_output([ldid, '-e', str(path)])), expected)
    return {'schema_version': 1, 'files_sha256': digests,
            'architecture': 'arm64', 'platform': 'IOS', 'deployment_target': '15.0',
            'entitlements_match': True, 'forbidden_swift_imports': [],
            'runtime_validated': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--record', action='store_true')
    parser.add_argument('--ldid', default='ldid')
    args = parser.parse_args()
    report = inspect(args.directory, args.ldid)
    manifest = args.directory / 'manifest.json'
    if args.record:
        if manifest.is_symlink():
            raise ValueError('Refusing symlink guest manifest')
        manifest.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    else:
        if manifest.is_symlink() or not manifest.is_file() or json.loads(manifest.read_text()) != report:
            raise ValueError('Guest manifest differs from actual artifacts; run make vphoned')
    print('Guest payload metadata, entitlements and manifest checked; runtime not tested')


if __name__ == '__main__':
    main()

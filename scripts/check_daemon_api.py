#!/usr/bin/env python3
"""Validate the isolated iOS API daemon's dependency pins and candidate artifact."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

from check_guest_payloads import output, validate_metadata

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'sources/VPhoneDaemon'
XCODE_PROJECT = PROJECT / 'VPhoneDaemon.xcodeproj/project.pbxproj'
LOCK = PROJECT / 'VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
EXPECTED = ROOT / 'dependencies/daemon-api-pins.json'


def pin_map(pins):
    result = {}
    for pin in pins:
        name = pin['identity']
        if name in result:
            raise ValueError(f'Duplicate dependency pin: {name}')
        result[name] = (pin['kind'], pin['location'], pin['state']['revision'], pin['state'].get('version'))
    return result


def check_pins(actual, expected):
    if pin_map(actual) != pin_map(expected):
        raise ValueError('API daemon dependencies differ from the fixed upstream pins')


REMOTE_REFERENCE = re.compile(
    r'isa = XCRemoteSwiftPackageReference;\s*repositoryURL = "([^"]+)";\s*requirement = \{([^}]*)\};')


def check_project_requirements(project_text, pins):
    """Every remote package in the Xcode project must be an exact pin of its resolved version."""
    versions = {pin['location']: pin['state'].get('version') for pin in pins}
    references = REMOTE_REFERENCE.findall(project_text)
    if not references:
        raise ValueError('API daemon project declares no remote package requirements')
    for location, body in references:
        fields = dict(re.findall(r'(\w+) = ([^;]+);', body))
        if location not in versions:
            raise ValueError(f'API daemon project package is not pinned: {location}')
        if fields.get('kind') != 'exactVersion' or fields.get('version') != versions[location]:
            raise ValueError(f'API daemon project requirement differs from its pin: {location}')


def check_checkouts(pins, checkouts):
    for pin in pins:
        directory = checkouts / pin['identity']
        revision = output('/usr/bin/git', '-C', str(directory), 'rev-parse', 'HEAD').strip()
        if revision != pin['state']['revision']:
            raise ValueError(f'Unexpected dependency checkout: {pin["identity"]}')
        if output('/usr/bin/git', '-C', str(directory), 'status', '--porcelain').strip():
            raise ValueError(f'Modified dependency checkout: {pin["identity"]}')
    # ArchiveKit's Package.swift prefers this local override when present.
    override = checkouts / 'libarchive.xcframework/BinaryTarget/libarchive.xcframework'
    if override.exists() or override.is_symlink():
        raise ValueError('Local ArchiveKit binary override is not allowed for candidate builds')


def inspect_candidate(directory, ldid, pins):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Candidate directory must be a real directory')
    names = ['vphoned', 'vphoned.plist', 'vphoned.entitlements.plist']
    digests = {}
    for name in names:
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing regular candidate artifact: {path}')
        digests[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    policy = plistlib.loads((PROJECT / 'Configuration/VPhoneDaemon.entitlements').read_bytes())
    if plistlib.loads((directory / 'vphoned.entitlements.plist').read_bytes()) != policy:
        raise ValueError('Candidate policy differs from the source entitlements')
    if (directory / 'vphoned.plist').read_bytes() != (PROJECT / 'Configuration/vphoned.plist').read_bytes():
        raise ValueError('Candidate launchd plist differs from the source')
    binary = directory / 'vphoned'
    if not os.access(binary, os.X_OK):
        raise ValueError('Candidate is not executable')
    validate_metadata(output('/usr/bin/lipo', '-archs', str(binary)),
                      output('/usr/bin/xcrun', 'vtool', '-show-build', str(binary)),
                      output('/usr/bin/nm', '-u', str(binary)),
                      plistlib.loads(subprocess.check_output([ldid, '-e', str(binary)])), policy)
    libraries = output('/usr/bin/otool', '-L', str(binary)).splitlines()[1:]
    for line in libraries:
        library = line.strip().split(' (')[0]
        if not library.startswith(('/usr/lib/', '/System/Library/', '@rpath/libswift')):
            raise ValueError(f'Unexpected guest dynamic dependency: {library}')
    return {'schema_version': 1, 'role': 'isolated-api-daemon-candidate',
            'activated': False, 'runtime_validated': False, 'api_version': 1, 'vsock_port': 1339,
            'architecture': 'arm64', 'platform': 'IOS', 'deployment_target': '15.0',
            'files_sha256': digests, 'pins': pins,
            'dynamic_libraries': [line.strip() for line in libraries]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkouts', type=Path)
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--record', action='store_true')
    parser.add_argument('--ldid', default='ldid')
    args = parser.parse_args()
    pins = json.loads(LOCK.read_text())['pins']
    check_pins(pins, json.loads(EXPECTED.read_text())['pins'])
    check_project_requirements(XCODE_PROJECT.read_text(), pins)
    if args.checkouts:
        check_checkouts(pins, args.checkouts)
    if args.candidate:
        report = inspect_candidate(args.candidate, args.ldid, pins)
        manifest = args.candidate / 'manifest.json'
        if manifest.is_symlink():
            raise ValueError('Candidate manifest must not be a symbolic link')
        if args.record:
            manifest.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
        elif json.loads(manifest.read_text()) != report:
            raise ValueError('Candidate manifest mismatch')
    print('API daemon pins and requested candidate checks passed; guest runtime not validated')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Validate an assembled vphone-launchpad.app (T26 B1).

Checks the Info.plist identity, the layout (embedded toolchain, no helper),
the localizations (en and zh-Hans only), the embedded-toolchain.json cdhashes
against the nested executables (and, with --reference, against the
vphone-cli.app they were copied from), the nested vphone-vm entitlements, and
the outer signature (`codesign --verify --strict --deep`).
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = 'com.vphone.cli.launchpad'
EXECUTABLE = 'vphone-launchpad'
LANGUAGES = ('en', 'zh-Hans')
HELPER = 'Contents/Helpers/vphone-cli.app'
MANIFEST = 'Contents/Resources/embedded-toolchain.json'
MANIFEST_SCHEMA = 'vphone.launchpad.embedded-toolchain'
NESTED = {'vphone-cli': 'vphoneCLI', 'vphone-vm': 'vphoneVM'}
HELPER_KEYS = ('SMPrivilegedExecutables', 'SMAuthorizedClients', 'VPhoneHelperSigningTeam')


def check_info(info):
    expected = {
        'CFBundleIdentifier': BUNDLE_ID,
        'CFBundleExecutable': EXECUTABLE,
        'CFBundlePackageType': 'APPL',
        'CFBundleDevelopmentRegion': 'en',
        'LSMinimumSystemVersion': '15.0',
        'NSPrincipalClass': 'NSApplication',
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f'Info.plist {key} is {info.get(key)!r}, expected {value!r}')
    if sorted(info.get('CFBundleLocalizations', [])) != sorted(LANGUAGES):
        raise ValueError(f'Info.plist CFBundleLocalizations is {info.get("CFBundleLocalizations")!r}, '
                         f'expected {list(LANGUAGES)!r}')
    for key in HELPER_KEYS:
        if key in info:
            raise ValueError(f'Info.plist declares {key}; helper registration is deferred')


def _lstat_kind(path):
    try:
        return stat.S_IFMT(os.lstat(path).st_mode)
    except FileNotFoundError:
        return None


def check_layout(app):
    required = {
        'Contents': stat.S_IFDIR,
        f'Contents/MacOS/{EXECUTABLE}': stat.S_IFREG,
        'Contents/Resources/AppIcon.icns': stat.S_IFREG,
        MANIFEST: stat.S_IFREG,
        'Contents/Helpers': stat.S_IFDIR,
        HELPER: stat.S_IFDIR,
        f'{HELPER}/Contents/MacOS/vphone-cli': stat.S_IFREG,
        f'{HELPER}/Contents/MacOS/vphone-vm': stat.S_IFREG,
    }
    for relative, kind in required.items():
        actual = _lstat_kind(app / relative)
        if actual is None:
            raise ValueError(f'Missing {relative}')
        if actual == stat.S_IFLNK:
            raise ValueError(f'Symbolic link: {relative}')
        if actual != kind:
            raise ValueError(f'Wrong file type: {relative}')
    if not os.access(app / f'Contents/MacOS/{EXECUTABLE}', os.X_OK):
        raise ValueError(f'Not executable: Contents/MacOS/{EXECUTABLE}')
    if (app / 'Contents/Library').exists():
        raise ValueError('Contents/Library exists; helper registration is deferred')
    helper = (app / HELPER).resolve()
    for dirpath, dirnames, filenames in os.walk(app):
        current = Path(dirpath)
        if current.resolve() == helper:
            dirnames[:] = []
            continue
        for name in dirnames + filenames:
            if (current / name).is_symlink():
                raise ValueError(f'Symbolic link: {(current / name).relative_to(app)}')


def check_localizations(app):
    helper = (app / HELPER).resolve()
    found = []
    for dirpath, dirnames, _ in os.walk(app):
        current = Path(dirpath)
        if current.resolve() == helper:
            dirnames[:] = []
            continue
        found += [current / name for name in dirnames if name.endswith('.lproj')]
    names = sorted(path.name for path in found)
    expected = sorted(f'{language}.lproj' for language in LANGUAGES)
    if names != expected:
        raise ValueError(f'Localizations are {names}, expected {expected}')
    for path in found:
        if path.parent != app / 'Contents/Resources':
            raise ValueError(f'Localization outside Contents/Resources: {path.relative_to(app)}')
        for table in ('Localizable.strings', 'InfoPlist.strings'):
            file = path / table
            if not file.is_file() or file.stat().st_size == 0:
                raise ValueError(f'Missing or empty {path.name}/{table}')


def check_manifest(manifest, actual, reference=None):
    if manifest.get('schema') != MANIFEST_SCHEMA or manifest.get('version') != 1:
        raise ValueError(f'Unexpected manifest schema {manifest.get("schema")!r} version {manifest.get("version")!r}')
    if not manifest.get('gitHash'):
        raise ValueError('Manifest has no gitHash')
    for name, key in NESTED.items():
        recorded = (manifest.get(key) or {}).get('cdhash')
        if not recorded or recorded != actual.get(name):
            raise ValueError(f'{name} cdhash {actual.get(name)!r} does not match manifest {recorded!r}')
        if reference is not None and reference.get(name) != actual.get(name):
            raise ValueError(f'{name} cdhash {actual.get(name)!r} differs from reference {reference.get(name)!r}')


def cdhash(path):
    output = subprocess.run(['codesign', '-dvvv', str(path)], capture_output=True, text=True, check=True).stderr
    for line in output.splitlines():
        if line.startswith('CDHash='):
            return line.split('=', 1)[1]
    raise ValueError(f'No CDHash for {path}')


def signing_identifier(path):
    output = subprocess.run(['codesign', '-dv', str(path)], capture_output=True, text=True, check=True).stderr
    for line in output.splitlines():
        if line.startswith('Identifier='):
            return line.split('=', 1)[1]
    return None


def check_nested_entitlements(app):
    expected = plistlib.loads((ROOT / 'sources/vphone.entitlements').read_bytes())
    executable = app / HELPER / 'Contents/MacOS/vphone-vm'
    signed = subprocess.check_output(['codesign', '-d', '--entitlements', '-', '--xml', str(executable)],
                                     stderr=subprocess.DEVNULL)
    actual = plistlib.loads(signed)
    for key, value in expected.items():
        if actual.get(key) != value:
            raise ValueError(f'Nested vphone-vm entitlement changed: {key}')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--reference', type=Path, help='The vphone-cli.app the toolchain was copied from')
    args = parser.parse_args(argv)
    app = args.app.resolve()
    check_info(plistlib.loads((app / 'Contents/Info.plist').read_bytes()))
    check_layout(app)
    check_localizations(app)
    actual = {name: cdhash(app / HELPER / 'Contents/MacOS' / name) for name in NESTED}
    reference = None
    if args.reference:
        reference = {name: cdhash(args.reference.resolve() / 'Contents/MacOS' / name) for name in NESTED}
    check_manifest(json.loads((app / MANIFEST).read_text()), actual, reference)
    check_nested_entitlements(app)
    subprocess.run(['codesign', '--verify', '--strict', '--deep', '--verbose=2', str(app)], check=True)
    identifier = signing_identifier(app)
    if identifier != BUNDLE_ID:
        raise ValueError(f'Outer signature identifier is {identifier!r}, expected {BUNDLE_ID!r}')
    print(f'Launchpad bundle: Info.plist, layout, localizations {", ".join(LANGUAGES)}, '
          f'cdhash vphone-cli {actual["vphone-cli"]} vphone-vm {actual["vphone-vm"]}'
          f'{" (= reference)" if reference else ""}, nested entitlements and outer signature verified')
    return 0


if __name__ == '__main__':
    sys.exit(main())

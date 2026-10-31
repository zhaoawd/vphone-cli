#!/usr/bin/env python3
"""Probe runtime capabilities and optionally compare the platform dependency lock."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import re
import sys


def lock_path(base):
    name = f'python-{sys.platform}-{platform.machine()}-{sys.version_info.major}.{sys.version_info.minor}.lock'
    path = Path(base) / 'dependencies' / name
    if not path.is_file():
        raise RuntimeError(f'No verified dependency lock for {name}; use macOS ARM64 Python 3.13 or 3.14')
    metadata = json.loads(path.with_suffix('.json').read_text())
    expected = metadata['requirements_sha256']
    if hashlib.sha256((Path(base) / 'requirements.txt').read_bytes()).hexdigest() != expected:
        raise RuntimeError('requirements.txt differs from the resolved lock inputs; regenerate the platform lock')
    return path


def versions_from_lock(path):
    result = {}
    for line in path.read_text().splitlines():
        match = re.match(r'^([A-Za-z0-9_.-]+)==([^\s\\]+)', line)
        if match:
            result[match[1]] = match[2]
    if not result:
        raise RuntimeError(f'Empty dependency lock: {path}')
    return result


def probe(lock=None):
    # Import inside the probe so a missing dependency still yields a JSON error.
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
    from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN
    from pyimg4 import IM4P
    from ipsw_parser.ipsw import IPSW
    import pymobiledevice3
    import typer

    encoded, count = Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN).asm('mov x0, #1; ret')
    decoded = list(Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN).disasm(bytes(encoded), 0))
    if count != 2 or len(encoded) != 8 or len(decoded) != 2:
        raise RuntimeError('ARM64 assembly/disassembly returned an incomplete result')
    if decoded[0].mnemonic not in ('mov', 'movz') or decoded[1].mnemonic != 'ret':
        raise RuntimeError('Capstone did not decode the assembled ARM64 instructions')
    if not hasattr(IPSW, 'create_from_path'):
        raise RuntimeError('ipsw-parser lacks IPSW.create_from_path')
    versions = {d.metadata['Name']: d.version for d in importlib.metadata.distributions()}
    differences = {}
    if lock:
        for name, expected in versions_from_lock(lock).items():
            try:
                actual = importlib.metadata.version(name)
            except importlib.metadata.PackageNotFoundError:
                actual = None
            if actual != expected:
                differences[name] = {'expected': expected, 'actual': actual}
    return {'ok': not differences, 'python': sys.executable, 'version': platform.python_version(),
            'platform': sys.platform, 'machine': platform.machine(), 'packages': versions,
            'lock': str(lock) if lock else None,
            'lock_sha256': hashlib.sha256(lock.read_bytes()).hexdigest() if lock else None,
            'differences': differences, 'capabilities': 'ARM64 assembly/disassembly, IM4P, IPSW.create_from_path, pymobiledevice3, typer'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--locked', action='store_true')
    parser.add_argument('--lock', type=Path)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    try:
        lock = args.lock or (lock_path(Path(__file__).resolve().parents[1]) if args.locked else None)
        report = probe(lock)
    except Exception as error:
        report = {'ok': False, 'error': str(error), 'python': sys.executable}
    if args.json:
        print(json.dumps(report, sort_keys=True))
    elif report['ok']:
        print('Python runtime OK: ' + report['capabilities'])
    else:
        print(json.dumps(report, sort_keys=True), file=sys.stderr)
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())

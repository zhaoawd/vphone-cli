#!/usr/bin/env python3
"""Provision a locked Python generation, then publish it after successful validation."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

from check_python_runtime import lock_path


def run(args, **kwargs):
    # Keep stdout reserved for the selected Python path / diagnostic report.
    subprocess.run([str(a) for a in args], check=True, stdout=sys.stderr, **kwargs)


def check(python, base, lock):
    try:
        result = subprocess.run([str(python), str(base / 'scripts/check_python_runtime.py'),
                                 '--lock', str(lock), '--json'], capture_output=True, text=True)
        report = json.loads(result.stdout)
        if result.returncode or not report.get('ok'):
            return None
        return report
    except (OSError, ValueError):
        return None


def repair_keystone(python):
    probe = subprocess.run([str(python), '-c',
        "from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN; assert len(Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN).asm('nop')[0]) == 4"],
        capture_output=True)
    if probe.returncode == 0:
        return None
    purelib = subprocess.check_output([str(python), '-c',
        "import sysconfig; print(sysconfig.get_paths()['purelib'])"], text=True).strip()
    destination = Path(purelib) / 'keystone/libkeystone.dylib'
    source = Path('/opt/homebrew/opt/keystone/lib/libkeystone.a')
    if not source.is_file():
        raise RuntimeError('Keystone native library missing; install Homebrew keystone')
    run(['/usr/bin/clang', '-shared', '-o', destination, '-Wl,-all_load', source,
         '-lc++', '-install_name', '@rpath/libkeystone.dylib'])
    return {'source': str(source.resolve()), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'output_sha256': hashlib.sha256(destination.read_bytes()).hexdigest()}


def publish(target, candidate):
    """Venv absolute paths remain stable; only the public symlink is replaced."""
    link = target.parent / f'.{target.name}-link-{uuid.uuid4().hex}'
    backup = None
    link.symlink_to(candidate)
    try:
        if target.exists() and not target.is_symlink():
            backup = candidate.parent / f'legacy-{uuid.uuid4().hex}'
            target.rename(backup)
        os.replace(link, target)
    except BaseException:
        if backup is not None:
            backup.rename(target)
        raise
    finally:
        link.unlink(missing_ok=True)
    # Retain older generations for inspection; no automatic cache deletion.


def ensure(base, target, force=False):
    base = base.resolve()
    # Do not resolve target: it may already point to an older generation.
    target = Path(os.path.abspath(target))
    lock = lock_path(base)
    if target == base or target == target.parent:
        raise RuntimeError('Refusing to replace a project or filesystem root with a venv')
    if target.is_dir() and not target.is_symlink() and any(target.iterdir()) and not (target / 'pyvenv.cfg').is_file():
        raise RuntimeError(f'Target is not a recognized virtual environment: {target}')
    target.parent.mkdir(parents=True, exist_ok=True)
    with (target.parent / f'.{target.name}.lock').open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        python = target / 'bin/python3'
        if not force and check(python, base, lock):
            return python
        generations = target.parent / f'.{target.name}.generations'
        generations.mkdir(exist_ok=True)
        candidate = Path(tempfile.mkdtemp(prefix='env-', dir=generations))
        try:
            run([sys.executable, '-m', 'venv', candidate])
            candidate_python = candidate / 'bin/python3'
            # Pin build tooling before source builds; do not use unpinned build isolation.
            tooling = candidate / 'build-requirements.txt'
            blocks = lock.read_text().split('\n\n')
            tooling.write_text('\n\n'.join(b for b in blocks if b.startswith(('pip==', 'setuptools==', 'wheel=='))) + '\n')
            flags = ['--require-hashes', '--no-build-isolation', '--disable-pip-version-check']
            run([candidate_python, '-m', 'pip', 'install', *flags, '-r', tooling])
            run([candidate_python, '-m', 'pip', 'install', *flags, '-r', lock])
            native = repair_keystone(candidate_python)
            run([candidate_python, '-m', 'pip', 'check'])
            report = check(candidate_python, base, lock)
            if not report:
                raise RuntimeError('Candidate Python failed locked runtime verification')
            report['native_keystone'] = native
            (candidate / 'vphone-environment.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
            publish(target, candidate)
        except BaseException:
            shutil.rmtree(candidate)
            raise
        return python


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--venv', required=True, type=Path)
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    try:
        print(ensure(args.base, args.venv, args.force))
    except Exception as error:
        print(f'Python environment unchanged: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

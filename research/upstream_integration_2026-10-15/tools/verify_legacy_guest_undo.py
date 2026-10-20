#!/usr/bin/env python3
"""Verify missing-evidence refusal on an explicitly selected stopped legacy VM.

Runs production CLI readers and the Undo entrypoint. It never installs firmware,
attaches images, creates generation evidence or starts a VM. CLI locking updates
the diagnostic runtime record. Full disk hashes are checked before and after.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def snapshot(vm):
    directory = os.open(vm, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = {}
        for name in ('Disk.img', 'config.plist', 'nvram.bin', 'SEPStorage', 'launchpad.json'):
            path = vm / name
            if not os.path.lexists(path):
                result[name] = None
                continue
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as stream:
                before = os.fstat(stream.fileno())
                assert stat.S_ISREG(before.st_mode), path
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                after = os.fstat(stream.fileno())
            keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_uid', 'st_gid')
            assert all(getattr(before, key) == getattr(after, key) == getattr(path.lstat(), key) for key in keys), path
            result[name] = dict(sha256=digest, **{key: getattr(after, key) for key in keys})
        return result
    finally:
        os.close(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    vm, cli, out = args.vm.resolve(strict=True), args.cli.resolve(strict=True), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[3]
    missing = ('.firmware-generations', '.firmware-desired-plan.json', '.cfw-history', '.firmware-transaction')
    assert not any(os.path.lexists(vm / name) for name in missing), 'This check requires a legacy VM with no generation/journal'
    assert not list(vm.glob('.cfw_disk.*')), 'Pending CFW transaction'
    started = time.monotonic()
    before = snapshot(vm)
    write(out / 'offline-before.json', before)
    commands = []
    env = dict(os.environ, VPHONE_PYTHON=str(repo / '.venv/bin/python3'), PYTHONDONTWRITEBYTECODE='1')

    def run(label, argv):
        result = subprocess.run([str(item) for item in argv], env=env, capture_output=True, text=True, timeout=60)
        row = dict(label=label, argv=[str(item) for item in argv], exitCode=result.returncode,
                   stdout=result.stdout, stderr=result.stderr)
        commands.append(row)
        write(out / 'offline-commands.json', commands)
        return row

    receipts = run('missing guest evidence', [cli, 'cfw', 'receipts', vm.name, '--library-root', vm.parent, '--json'])
    # The placeholder is explicitly an absent expected generation, never a VM
    # generation or authority to construct an Undo candidate.
    absent = '0' * 64
    preview = run('missing checkpoint preview', [repo / '.venv/bin/python3', repo / 'scripts/vm_lock.py', vm,
        'fw-receipts', '--', repo / '.venv/bin/python3', repo / 'scripts/cfw_disk_txn.py', 'preview-undo',
        '--generation', absent, '--declaration', 'dyld-cfw-camera', vm])
    undo = run('missing live plan writer refusal', [cli, 'cfw', 'undo', vm.name, '--library-root', vm.parent,
        '--generation', absent, '--declaration', 'dyld-cfw-camera'])
    after = snapshot(vm)
    write(out / 'offline-after.json', after)
    checks = dict(receiptsUnknown=receipts['exitCode'] == 0 and
                  json.loads(receipts['stdout']) == dict(schemaVersion=1, state='unknown'),
                  previewRefused=preview['exitCode'] != 0 and
                  'no committed guest checkpoint; Undo is unavailable' in preview['stderr'],
                  writerRefused=undo['exitCode'] != 0 and
                  'CFW requires a current bound desired plan; missing/legacy selection cannot authorize installation' in undo['stderr'],
                  protectedFilesUnchanged=before == after,
                  evidenceNotCreated=not any(os.path.lexists(vm / name) for name in missing),
                  noStaging=not list(vm.glob('.cfw_disk.*')))
    summary = dict(schemaVersion=1, state='passed' if all(checks.values()) else 'failed',
                   scope='legacy-missing-evidence-refusal', vm=str(vm), checks=checks,
                   diskUnchanged=before['Disk.img'] == after['Disk.img'],
                   positiveUndoValidated=False, seconds=time.monotonic() - started)
    write(out / 'offline-result.json', summary)
    print(json.dumps(summary, sort_keys=True))
    assert all(checks.values()), checks


if __name__ == '__main__':
    main()

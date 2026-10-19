#!/usr/bin/env python3
"""Read-only production reader and retained-original checks on the chosen VM."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from inspect_roothide_journals import VM, metadata

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts'))
import cfw_disk_txn as transaction


def main():
    fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    old = os.environ.get('VPHONE_VM_LOCK_FD')
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ['VPHONE_VM_LOCK_FD'] = str(fd)
        paths = sorted((VM / '.cfw-history').glob('*/transaction.json')) + sorted(VM.glob('.cfw_disk.*/transaction.json'))
        before = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
        disk_before = metadata(VM / 'Disk.img')
        runtime_before = (VM / '.vphone-runtime.json').read_bytes()
        result = dict(vm=str(VM), readers={}, journals=[])
        result['readers']['inspect'] = transaction.inspect_guest(VM)
        assert result['readers']['inspect'] is None
        # An absent expected generation is used only to test missing-evidence
        # refusal. No generation or write capability is constructed.
        try:
            transaction.preview_guest_undo(VM, '0' * 64, ['dyld-cfw-camera'])
        except transaction.Refused as error:
            result['readers']['previewRefusal'] = str(error)
            assert 'no committed guest checkpoint; Undo is unavailable' in str(error)
        else:
            raise AssertionError('Legacy publication unexpectedly authorized an Undo preview')
        for path in paths:
            record = transaction.load_record(path.parent)
            row = dict(path=str(path),version=record['version'],status=record['status'],
                       currentIsStaged=transaction.is_same(VM / 'Disk.img', record['staged']),
                       currentIsOriginal=transaction.is_same(VM / 'Disk.img', record['original']))
            if record['status'] == 'published':
                original_path = path.parent / 'Disk.img'
                original_fd = os.open(original_path, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    row['retainedOriginalCheck'] = transaction.verify_original(original_fd, record)
                finally:
                    os.close(original_fd)
                assert row['retainedOriginalCheck']['unchanged'] is True
                row['currentMtimeEqualsRecordedStaged'] = disk_before['st_mtime_ns'] == record['staged']['mtime_ns']
            result['journals'].append(row)
        result['journalBytesUnchanged'] = before == {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
        result['diskMetadataUnchanged'] = disk_before == metadata(VM / 'Disk.img')
        result['runtimeBytesUnchanged'] = runtime_before == (VM / '.vphone-runtime.json').read_bytes()
        assert result['journalBytesUnchanged'] and result['diskMetadataUnchanged'] and result['runtimeBytesUnchanged']
        result['state'] = 'passed'
        result['positiveUndoQualified'] = False
        print(json.dumps(result, indent=2))
    finally:
        if old is None:
            os.environ.pop('VPHONE_VM_LOCK_FD', None)
        else:
            os.environ['VPHONE_VM_LOCK_FD'] = old
        os.close(fd)


if __name__ == '__main__':
    main()

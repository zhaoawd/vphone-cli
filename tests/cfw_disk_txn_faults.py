"""Test-only entry for scripts/cfw_disk_txn.py with injected faults.

Usage: cfw_disk_txn_faults.py SCRIPT ARGS...; CFW_TXN_FAULTS is a comma list:
clone (clone unavailable), copy (full copy fails), corrupt (copy differs from
the original), swap (publication rename fails with EIO), swap-unsupported
(RENAME_SWAP reports ENOTSUP, as on HFS+), excl-publish (the RENAME_EXCL step
that places the staged image fails), replace-after-stage (the VM's Disk.img is
replaced by another file after a successful stage). The production
script carries no fault hooks; this wrapper replaces its functions.
"""
import errno
import importlib.util
import json
import os
from pathlib import Path
import sys

script = sys.argv[1]
spec = importlib.util.spec_from_file_location('cfw_disk_txn', script)
txn = importlib.util.module_from_spec(spec)
sys.modules['cfw_disk_txn'] = txn
spec.loader.exec_module(txn)
faults = set(filter(None, os.environ.get('CFW_TXN_FAULTS', '').split(',')))

# This suite isolates disk copy/swap/cleanup and uses a disposable installer.
# Actual provenance production and publication are exercised in
# test_undo_provenance; there is no production bypass flag.
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from patchers import undo_provenance
def synthetic_provenance(work, record):
    if record.get('version') != 2 or record.get('provenanceMode') != 'required':
        raise ValueError('old records permit recovery only')
undo_provenance.verify_publication = synthetic_provenance


def failing(code):
    def raiser(*_args, **_kwargs):
        raise OSError(code, os.strerror(code))
    return raiser


if 'clone' in faults:
    txn.clone_file = failing(errno.ENOTSUP)
if 'copy' in faults:
    txn.copy_file = failing(errno.EIO)
if 'corrupt' in faults:
    real_copy = txn.copy_file

    def corrupt(source_fd, destination, size):
        digest = real_copy(source_fd, destination, size)
        with open(destination, 'r+b') as stream:
            first = stream.read(1)
            stream.seek(0)
            stream.write(bytes([first[0] ^ 0xff]) if first else b'\xff')
        return digest
    txn.copy_file = corrupt
if 'swap' in faults:
    txn.swap_files = failing(errno.EIO)
if 'swap-unsupported' in faults:
    txn.swap_files = failing(errno.ENOTSUP)
if 'excl-publish' in faults:
    real_move = txn.move_exclusive

    def move(source, destination):
        # Fail only the step that would place the staged image at Disk.img.
        if Path(source).parent.name.startswith('.cfw_disk.') and Path(source).name == 'Disk.img':
            raise OSError(errno.EIO, os.strerror(errno.EIO))
        return real_move(source, destination)
    txn.move_exclusive = move

status = txn.main(sys.argv[2:])
if status == 0 and sys.argv[2:3] == ['stage'] and 'legacy-record' in faults:
    work = Path(sys.argv[-1]); record = txn.load_record(work)
    record['version'] = 1; record.pop('provenanceMode')
    txn.save_record(work,record)
if status == 0 and sys.argv[2:3] == ['stage'] and 'replace-after-stage' in faults:
    vm = Path(os.environ['TEST_MOUNTS']).parent
    os.rename(vm / 'Disk.img', vm / 'Disk.img.moved')
    (vm / 'Disk.img').write_bytes(b'replacement\n')
sys.exit(status)

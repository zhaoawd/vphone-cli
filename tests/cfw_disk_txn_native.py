"""Opt-in native check of scripts/cfw_disk_txn.py on disposable APFS and HFS+ volumes.

Creates two small disk images with hdiutil (no root), attaches them under a
temporary directory and runs stage -> publish -> finish against a 96 MiB sparse
Disk.img on each. APFS must take the clone path; HFS+ has no clonefile and must
take the verified sparse full copy. Both must publish by RENAME_SWAP and keep
the original bytes as .cfw-history/<id>/Disk.img. Never touches a VM directory.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SIZE = 96 << 20


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def txn(command, fd, vm, work, *extra):
    # Each command takes the VM lock like the driver's operation tree does.
    args = [sys.executable, str(ROOT / 'scripts/vm_lock.py'), str(vm), 'cfw-native', '--',
            sys.executable, str(ROOT / 'scripts/cfw_disk_txn.py'), command, '--fd', str(fd),
            '--owner-pid', str(os.getpid()), *extra, str(vm), str(work)]
    return subprocess.run(args, pass_fds=(fd,), capture_output=True, text=True)


def exercise(volume, expected_method):
    vm = volume / 'vm'
    vm.mkdir()
    disk = vm / 'Disk.img'
    with open(disk, 'wb') as stream:
        stream.truncate(SIZE)
        for offset in (0, 40 << 20, SIZE - (1 << 20)):
            stream.seek(offset)
            stream.write(os.urandom(512 << 10))
    original_sha, original_ino = sha256(disk), disk.stat().st_ino
    fd = os.open(disk, os.O_RDONLY)
    try:
        work = vm / '.cfw_disk.native01'
        work.mkdir(mode=0o700)
        staged = txn('stage', fd, vm, work)
        assert staged.returncode == 0, staged.stderr
        record = json.loads((work / 'transaction.json').read_text())
        assert record['method'] == expected_method, record
        copy = work / 'Disk.img'
        assert sha256(copy) == original_sha
        if expected_method == 'clone':
            # HFS+ keeps no holes; only APFS can show a sparse staged image.
            assert copy.stat().st_blocks * 512 < SIZE // 2, copy.stat().st_blocks
        else:
            assert record['copy']['source_sha256'] == record['copy']['copy_sha256'] == original_sha, record
            print(f'  {volume.name}: original blocks={disk.stat().st_blocks} copy blocks={copy.stat().st_blocks}')
        assert record['original']['sample']['kind'].startswith('sampled'), record['original']['sample']
        for phase in ('pre-mount', 'pre-install'):
            checked = txn('check', fd, vm, work, '--phase', phase)
            assert checked.returncode == 0, checked.stderr
        with open(copy, 'r+b') as stream:
            stream.seek(512)
            stream.write(b'CFW-PATCHED')
        patched_sha = sha256(copy)
        published = txn('publish', fd, vm, work)
        assert published.returncode == 0, published.stderr
        finished = txn('finish', fd, vm, work, '--exit-code', '0')
        assert finished.returncode == 0, finished.stderr
        location = Path(finished.stdout.strip())
        record = json.loads((location / 'transaction.json').read_text())
        assert record['status'] == 'published' and record['original_check']['unchanged'], record
        assert all(record['after_swap'].values()), record
        assert sha256(disk) == patched_sha
        assert sha256(location / 'Disk.img') == original_sha
        assert (location / 'Disk.img').stat().st_ino == original_ino
        print(f'PASS: {volume.name}: method={record["method"]} clone_error={record["clone_error"]} '
              f'publish={record["publish_method"]} swap_error={record.get("swap_error")}; '
              'previous disk retained with original SHA-256 and inode')
    finally:
        os.close(fd)


def main():
    with tempfile.TemporaryDirectory(prefix='cfw-txn-native-') as temp:
        root = Path(temp).resolve()
        mounts = []
        try:
            for fs, method in (('APFS', 'clone'), ('HFS+', 'copy')):
                name = 'apfs' if fs == 'APFS' else 'hfs'
                # Sparse bundle-free image: 3 GiB capacity (the copy path requires
                # allocated size + 2 GiB free) without allocating it on the host.
                image = root / f'{name}.sparseimage'
                run('hdiutil', 'create', '-type', 'SPARSE', '-size', '3g', '-fs', fs, '-volname', f'CFWTxn{name}', str(image))
                mount = root / name
                mount.mkdir()
                run('hdiutil', 'attach', '-nobrowse', '-mountpoint', str(mount), str(image))
                mounts.append(mount)
                exercise(mount, method)
        finally:
            for mount in mounts:
                if f' on {mount} (' in run('/sbin/mount').stdout:
                    run('hdiutil', 'detach', str(mount))
            info = plistlib.loads(run('hdiutil', 'info', '-plist').stdout.encode())
            for image in info.get('images', []):
                if Path(image.get('image-path', '')).parent == root:
                    for entry in image.get('system-entities', []):
                        if entry.get('content-hint') == 'GUID_partition_scheme':
                            run('hdiutil', 'detach', entry['dev-entry'])


if __name__ == '__main__':
    main()

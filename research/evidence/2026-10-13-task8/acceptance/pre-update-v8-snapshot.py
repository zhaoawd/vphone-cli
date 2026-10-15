"""Capture the stopped Task 8 copy before the next official kernel update."""
from pathlib import Path
import fcntl
import hashlib
import json
import os
import plistlib
import stat
import subprocess

E = Path(__file__).resolve().parent
VM = Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
OUT = E / 'pre-update-v8-snapshot.json'
assert not OUT.exists()
fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
try:
    assert not (VM / '.firmware-transaction').exists()
    observation = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
    assert not any(os.path.realpath(i.get('image-path', '')) == str(VM / 'Disk.img')
                   for i in observation.get('images', []))
    prior = json.loads((E / 'baseline-digests.json').read_text())[str(VM)]
    files = {}
    for name in prior:
        path = VM / name
        before = path.lstat()
        assert stat.S_ISREG(before.st_mode)
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            while block := stream.read(16 << 20):
                digest.update(block)
        after = path.lstat()
        keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        assert all(getattr(before, key) == getattr(after, key) for key in keys)
        assert after.st_ino == prior[name]['inode']
        files[name] = {'sha256': digest.hexdigest(), 'inode': after.st_ino,
                       'metadata': {key: getattr(after, key) for key in keys}}
    assert files['Disk.img']['sha256'] == '9918d2bdd8f4cb9b653ebe0a5d552cd3f61bb4986421652f08c4049adfb82531'
    result = {'passed': True, 'vm': str(VM), 'files': files,
              'binding': json.loads((VM / 'launchpad.json').read_text()),
              'receipt_sha256': hashlib.sha256((VM / '.firmware-component-receipts.json').read_bytes()).hexdigest(),
              'pending': False, 'attached': False}
    OUT.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
finally:
    os.close(fd)

#!/usr/bin/env python3
"""Read only the selected roothide VM's CFW metadata under its directory lock."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess

VM = Path('/Users/kolar/github/vphone-cli/vm-roothide-b33-20261010')


def metadata(path):
    value = path.lstat()
    return {key: getattr(value, key) for key in
            ('st_dev', 'st_ino', 'st_size', 'st_mode', 'st_uid', 'st_gid', 'st_mtime_ns', 'st_ctime_ns')}


def main():
    assert not VM.is_symlink() and VM.resolve(strict=True) == VM
    fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = metadata(VM / 'Disk.img')
        result = dict(vm=str(VM),directoryLockAcquired=True,currentDisk=before,
                      generationPresent=(VM / '.firmware-generations').exists(),
                      desiredPresent=(VM / '.firmware-desired-plan.json').exists(), journals=[])
        images = [VM / 'Disk.img']
        archives = sorted((VM / '.cfw-history').iterdir()) + sorted(VM.glob('.cfw_disk.*'))
        for archive in archives:
            info = archive.lstat()
            assert stat.S_ISDIR(info.st_mode) and not archive.is_symlink()
            path = archive / 'transaction.json'
            stream_fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(stream_fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                assert stat.S_ISREG(info.st_mode) and info.st_size <= 8 << 20
                raw = stream.read((8 << 20) + 1)
            assert len(raw) <= 8 << 20
            row = dict(path=str(path),sha256=hashlib.sha256(raw).hexdigest(),record=json.loads(raw), files=[])
            for member in sorted(archive.iterdir()):
                item = dict(name=member.name, metadata=metadata(member))
                row['files'].append(item)
                if member.name in ('Disk.img','Disk.img.previous'):
                    images.append(member)
            result['journals'].append(row)
        holders = subprocess.run(['/usr/sbin/lsof','-nP','-Fpcn','--'] + [str(p) for p in images],
                                 capture_output=True, text=True, timeout=15)
        result['diskHolders'] = dict(exitCode=holders.returncode,stdout=holders.stdout,stderr=holders.stderr)
        attachments = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
        result['attachments'] = [row for row in attachments['images'] if Path(row['image-path']).parent == VM
                                 or VM in Path(row['image-path']).parents]
        result['diskMetadataUnchanged'] = metadata(VM / 'Disk.img') == before
        assert result['diskMetadataUnchanged']
        print(json.dumps(result, indent=2))
    finally:
        os.close(fd)


if __name__ == '__main__':
    main()

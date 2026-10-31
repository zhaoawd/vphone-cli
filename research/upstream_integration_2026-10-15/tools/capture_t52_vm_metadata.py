#!/usr/bin/env python3
"""Read-only metadata capture for the named independent T52 VM."""
import hashlib
import json
from pathlib import Path
import stat
import sys

root = Path(__file__).resolve().parents[3]
vm = root / '.build/t51rt/lib/t52-v2'
result = dict(vm=str(vm), files={}, history=[])
for name in ('Disk.img', 'config.plist', 'SEPStorage', 'nvram.bin',
             'udid-prediction.txt', 'restore-info.json', 'launchpad.json'):
    path = vm / name
    if not path.exists():
        result['files'][name] = None
        continue
    info = path.stat()
    row = dict(device=info.st_dev, inode=info.st_ino, size=info.st_size,
               mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid,
               mtimeNs=info.st_mtime_ns)
    if name != 'Disk.img':
        row['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    result['files'][name] = row
history = vm / '.cfw-history'
if history.exists():
    result['history'] = sorted(path.name for path in history.iterdir())
Path(sys.argv[1]).write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))

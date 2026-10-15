"""Restore only the stopped test-copy binding owner after a root host rebind."""
from pathlib import Path
import fcntl, hashlib, json, os, plistlib, re, stat, subprocess, sys

E = Path(__file__).resolve().parent
VM = Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
assert len(sys.argv) == 3 and re.fullmatch(r'[a-z0-9-]+', sys.argv[1])
label, rebind_label = sys.argv[1:]
assert re.fullmatch(r'[a-z0-9-]+', rebind_label)
assert os.geteuid() == 0
record = json.loads((E / (rebind_label + '-host-rebind-check.json')).read_text())
assert record['passed'] is True
expected = record['after']['binding_sha256']
out = (E / (label + '-binding-owner-check.json')).open('x')
result = {'passed': False, 'binding_sha256': expected, 'rebind_label': rebind_label}
lock = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
fd = None
try:
    assert not (VM / '.firmware-transaction').exists()
    assert not (VM / '.firmware-desired-pending.json').exists()
    images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
    assert not [i for i in images.get('images', []) if 'vphone-task8-acceptance-vms' in i.get('image-path', '')]
    processes = subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True)
    assert not any('vphone-vm ' in p and '--config ' + str(VM / 'config.plist') + ' ' in p for p in processes.splitlines())
    owner = os.fstat(lock)
    config = (VM / 'config.plist').lstat()
    assert owner.st_uid == config.st_uid == 2035870432 and owner.st_gid == config.st_gid == 0
    fd = os.open(VM / 'launchpad.json', os.O_RDONLY | os.O_NOFOLLOW)
    before = os.fstat(fd)
    assert stat.S_ISREG(before.st_mode) and stat.S_IMODE(before.st_mode) == 0o600
    assert before.st_uid == 0 and before.st_gid == 0 and before.st_nlink == 1
    raw = os.read(fd, before.st_size + 1)
    assert len(raw) == before.st_size and hashlib.sha256(raw).hexdigest() == expected
    result['before'] = {'uid': before.st_uid, 'gid': before.st_gid, 'mode': stat.S_IMODE(before.st_mode), 'inode': before.st_ino}
    os.fchown(fd, owner.st_uid, owner.st_gid)
    after = os.fstat(fd)
    named = (VM / 'launchpad.json').lstat()
    os.lseek(fd, 0, os.SEEK_SET)
    assert os.read(fd, after.st_size + 1) == raw
    assert all(getattr(before, k) == getattr(after, k) == getattr(named, k) for k in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_mode', 'st_nlink'))
    assert after.st_uid == named.st_uid == owner.st_uid and after.st_gid == named.st_gid == owner.st_gid
    result['after'] = {'uid': after.st_uid, 'gid': after.st_gid, 'mode': stat.S_IMODE(after.st_mode), 'inode': after.st_ino}
    result['passed'] = True
except BaseException as error:
    result['error'] = repr(error)
    raise
finally:
    if fd is not None:
        os.close(fd)
    os.close(lock)
    out.write(json.dumps(result, indent=2) + '\n')
    out.close()
    print(json.dumps(result))

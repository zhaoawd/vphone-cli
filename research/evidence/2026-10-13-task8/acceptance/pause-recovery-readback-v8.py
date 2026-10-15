"""Independent exact-file verification after official paused-update recovery."""
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
TX = '76e115c5-70ff-4484-8358-a357e59ce1e5'
OUT = E / 'kernel-update-v8-pause-recovery-readback.json'
assert not OUT.exists()
fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
result = {'passed': False, 'transaction_id': TX}
try:
    assert not (VM / '.firmware-transaction').exists()
    baseline = json.loads((E / 'pre-update-v8-snapshot.json').read_text())
    assert baseline['passed'] is True and baseline['vm'] == str(VM)
    assert set(baseline['files']) == {'Disk.img', 'nvram.bin', 'SEPStorage', 'config.plist',
                                      'AVPBooter.vresearch1.bin', 'AVPSEPBooter.vresearch1.bin'}
    files = {}
    for name, old in baseline['files'].items():
        path = VM / name
        handle = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            before = os.fstat(handle)
            assert stat.S_ISREG(before.st_mode)
            digest = hashlib.sha256()
            with os.fdopen(handle, 'rb', closefd=False) as stream:
                while block := stream.read(16 << 20):
                    digest.update(block)
            after, named = os.fstat(handle), path.lstat()
            keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
            assert all(getattr(before, k) == getattr(after, k) == getattr(named, k) for k in keys)
            files[name] = {'sha256': digest.hexdigest(), 'inode': after.st_ino,
                           'same_content': digest.hexdigest() == old['sha256'],
                           'inode_unchanged': after.st_ino == old['inode'],
                           'device_unchanged': after.st_dev == old['metadata']['st_dev'],
                           'size_unchanged': after.st_size == old['metadata']['st_size']}
        finally:
            os.close(handle)
    result['files'] = files
    assert all(all(v[k] for k in ('same_content', 'inode_unchanged', 'device_unchanged', 'size_unchanged')) for v in files.values())
    result['binding_unchanged'] = (VM / 'launchpad.json').read_bytes() == (E / 'binding-before-update-v8.json').read_bytes()
    result['receipt_unchanged'] = hashlib.sha256((VM / '.firmware-component-receipts.json').read_bytes()).hexdigest() == baseline['receipt_sha256']
    assert result['binding_unchanged'] and result['receipt_unchanged']
    raw = (VM / '.firmware-history' / TX / 'journal.json').read_bytes()
    journal = json.loads(raw)
    disk = journal['kernelDisk']
    assert journal['id'] == TX and journal['kernelOnly'] is True
    assert journal['version'] == 3
    assert journal['phase'] == 'rollingBack' and disk['direction'] == 'reverse'
    assert disk['cursor'] == 0 and disk['pending'] is False
    assert disk['originalSHA256'] == baseline['files']['Disk.img']['sha256']
    (E / 'kernel-update-v8-pause-recovered-journal.json').write_bytes(raw)
    result['archive'] = {'phase': journal['phase'], 'direction': disk['direction'], 'cursor': disk['cursor'], 'pending': disk['pending']}
    result['passed'] = True
except BaseException as error:
    result['error'] = repr(error)
    raise
finally:
    try:
        data = subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist'])
        result['task8_attachments'] = [i for i in plistlib.loads(data).get('images', [])
                                       if 'vphone-task8-acceptance-vms' in i.get('image-path', '')]
        result['pending_transaction'] = (VM / '.firmware-transaction').exists()
        if result['task8_attachments'] or result['pending_transaction']:
            result['passed'] = False
    except BaseException as error:
        result['passed'] = False
        result['cleanup_observation_error'] = repr(error)
    os.close(fd)
    OUT.write_text(json.dumps(result, indent=2, default=str) + '\n')
    print(json.dumps(result, default=str))
    if not result['passed']:
        raise RuntimeError('Paused update recovery verification failed')

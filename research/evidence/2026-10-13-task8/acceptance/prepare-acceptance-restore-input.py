"""Copy the verified generation Restore tree required by public desired-plan."""
from pathlib import Path
import fcntl, hashlib, json, os, plistlib, stat, subprocess, uuid

E = Path(__file__).resolve().parent
VM = Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
GEN = 'd8d780c97a23b5ea398df872a73ad7aead24af90a08e35cea39c08524e927d62'
root = VM / '.firmware-generations' / GEN
manifest = json.loads((root / 'manifest.json').read_text())
assert manifest == json.loads((E / 'prepared-generation-manifest.json').read_text())
originals = [x for x in manifest['content']['originals'] if 'Restore' in x['name']]
assert len(originals) == 1 and originals[0]['name'] == 'iPhone17,3_26.1_23B85_Restore'
name, expected = originals[0]['name'], originals[0]['sha256']
source = root / 'originals' / name
target = VM / name
stage = VM / ('.task8-restore-input-' + str(uuid.uuid4()))
result = {'passed': False, 'source': str(source), 'target': str(target), 'generation': GEN, 'expected_tree_sha256': expected}
output = (E / 'kernel-v9-plan-b-restore-input-check.json').open('x')
lock = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
def tree(path):
    before = path.lstat()
    h = hashlib.sha256()
    if stat.S_ISDIR(before.st_mode):
        h.update(b'directory\0')
        names = sorted(os.listdir(path))
        for child in names:
            h.update((child + '\0' + tree(path / child) + '\0').encode())
        after = path.lstat()
        assert stat.S_ISDIR(after.st_mode) and before.st_dev == after.st_dev and before.st_ino == after.st_ino
        assert sorted(os.listdir(path)) == names
    else:
        assert stat.S_ISREG(before.st_mode) and before.st_nlink == 1
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            opened = os.fstat(fd)
            assert all(getattr(before, k) == getattr(opened, k) for k in keys)
            h.update(b'file\0')
            with os.fdopen(fd, 'rb', closefd=False) as f:
                while chunk := f.read(1 << 20):
                    h.update(chunk)
            after = os.fstat(fd)
            named = path.lstat()
            assert all(getattr(before, k) == getattr(after, k) == getattr(named, k) for k in keys)
        finally:
            os.close(fd)
    return h.hexdigest()
def observe():
    names = ['Disk.img', 'nvram.bin', 'SEPStorage', 'config.plist', 'AVPBooter.vresearch1.bin', 'AVPSEPBooter.vresearch1.bin']
    return {'files': {n: {k: getattr((VM / n).lstat(), k) for k in keys} for n in names},
            'generation_manifest_sha256': hashlib.sha256((root / 'manifest.json').read_bytes()).hexdigest(),
            'metadata_sha256': {n: hashlib.sha256((VM / n).read_bytes()).hexdigest() for n in ['launchpad.json', '.firmware-component-receipts.json', '.firmware-desired-plan.json']}}
try:
    assert not target.exists() and not target.is_symlink() and not stage.exists()
    assert not [p for p in VM.iterdir() if p.is_dir() and 'Restore' in p.name]
    assert not (VM / '.firmware-transaction').exists() and not (VM / '.firmware-desired-pending.json').exists()
    images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
    assert not [i for i in images.get('images', []) if 'vphone-task8-acceptance-vms' in i.get('image-path', '')]
    result['before'] = observe()
    result['source_before_tree_sha256'] = tree(source)
    assert result['source_before_tree_sha256'] == expected
    command = ['/bin/cp', '-cR', str(source), str(stage)]
    subprocess.run(command, check=True)
    result['copy_command'] = command
    result['candidate_tree_sha256'] = tree(stage)
    assert result['candidate_tree_sha256'] == expected
    version_names = ['iPhone-BuildManifest.plist', 'BuildManifest.plist']
    result['version_manifests_sha256'] = {n: hashlib.sha256((source / n).read_bytes()).hexdigest() for n in version_names}
    assert all(hashlib.sha256((stage / n).read_bytes()).hexdigest() == result['version_manifests_sha256'][n] for n in version_names)
    assert not target.exists() and not target.is_symlink()
    os.rename(stage, target)
    assert [p.name for p in VM.iterdir() if p.is_dir() and 'Restore' in p.name] == [name]
    result['source_after_tree_sha256'] = tree(source)
    assert result['source_after_tree_sha256'] == expected
    result['after'] = observe()
    assert result['after'] == result['before']
    assert not (VM / '.firmware-transaction').exists() and not (VM / '.firmware-desired-pending.json').exists()
    result['passed'] = True
except BaseException as error:
    result['error'] = repr(error)
    raise
finally:
    os.close(lock)
    output.write(json.dumps(result, indent=2) + '\n')
    output.close()
    print(json.dumps({k: v for k, v in result.items() if k not in ('before', 'after')}))

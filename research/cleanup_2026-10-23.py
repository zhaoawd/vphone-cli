"""Execute the eight explicitly approved cleanup targets and retain an audit."""
import datetime
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'research/evidence/cleanup-2026-10-23'
VM = ROOT / '.build/t51rt/lib/t52-v2'
DIRECTORIES = [
    '.build/t51rt/lib/base',
    '.build/t51rt/lib/target',
    '.build/t51rt/lib/t52-environment',
    '.build/t52-camera-interface-20261022/pre-deployment-vm-backup',
    '.build/t52-real-20261021/v2-first-binding-backup',
]
OLD_IDS = [
    'environment-7c8a48f4-42d2-4838-84d3-18e1541d59f7',
    'environment-728bf0d4-fa9d-4c12-b5f9-413c93cccb11',
    'environment-d27caf08-b214-4b7e-8347-9a0f23400404',
]
DISKS = [VM / '.environment-history' / name / 'Disk.img' for name in OLD_IDS]
TARGETS = [ROOT / name for name in DIRECTORIES] + DISKS


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity(path):
    s = path.lstat()
    return dict(dev=s.st_dev, ino=s.st_ino, mode=s.st_mode, size=s.st_size,
                mtime_ns=s.st_mtime_ns, blocks=s.st_blocks, uid=s.st_uid, gid=s.st_gid)


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def evidence():
    base = ROOT / 'research/upstream_integration_2026-10-15/evidence'
    results = {}
    for name in ['T52-real-20261021', 'T52-signature-camera-20261022',
                 'T52-provider-fix-20261023/runtime']:
        manifest = json.loads((base / name / 'manifest.json').read_text())
        rows = manifest.get('files', manifest.get('archived', []))
        for row in rows:
            p = base / name / row['path']
            assert p.stat().st_size == row['bytes'] and sha(p) == row['sha256'], str(p)
        results[name] = len(rows)
    return results


def protected():
    result = {}
    for directory in ['.cfw-history', '.firmware-generations', '.firmware-history']:
        base = VM / directory
        for parent, dirs, files in os.walk(base, onerror=lambda error: (_ for _ in ()).throw(error)):
            for name in dirs + files:
                p = Path(parent) / name
                result[str(p.relative_to(ROOT))] = identity(p)
    latest = VM / '.environment-history/environment-4e212cce-3c29-4415-9c6b-2a1e75e4ad55'
    for p in latest.iterdir():
        result[str(p.relative_to(ROOT))] = identity(p)
    for name in OLD_IDS:
        for leaf in ['transaction.json', 'environment-update.json']:
            p = VM / '.environment-history' / name / leaf
            result[str(p.relative_to(ROOT))] = dict(identity(p), sha256=sha(p))
    return result


def main():
    assert sys.argv[1:] in [[], ['--apply']]
    apply = sys.argv[1:] == ['--apply']
    OUT.mkdir(exist_ok=True)
    assert not (OUT / 'result.json').exists(), 'Previous cleanup result exists'
    handles = []
    try:
        inventory = {}
        initial = {}
        for p in TARGETS:
            assert p.resolve(strict=True) == p and p.is_relative_to(ROOT), str(p)
            fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            initial[str(p)] = identity(p)
            if p in DISKS:
                assert stat.S_ISREG(p.lstat().st_mode)
                assert json.loads((p.parent / 'transaction.json').read_text())['status'] == 'published'
                inventory[str(p.relative_to(ROOT))] = identity(p)
                continue
            assert p.is_dir()
            for parent, dirs, files in os.walk(p, onerror=lambda error: (_ for _ in ()).throw(error)):
                assert not os.path.ismount(parent), parent
                assert os.access(parent, os.W_OK | os.X_OK), 'Unwritable directory: ' + parent
                for name in dirs + files:
                    f = Path(parent) / name
                    inventory[str(f.relative_to(ROOT))] = identity(f)
            # Preserve small root records and transaction records separately.
            for f in p.rglob('*.json'):
                if f.is_symlink() or f.stat().st_size > 2 << 20:
                    continue
                if f.parent != p and f.name not in ['transaction.json', 'checkpoint.json', 'RebaseJournal.json']:
                    continue
                dest = OUT / 'metadata' / f.relative_to(ROOT)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(f, dest)
            dest = OUT / 'metadata' / p.relative_to(ROOT) / 'config.plist'
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(p / 'config.plist', dest)
        images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
        for image in images.get('images', []):
            path = Path(image.get('image-path', '/nonexistent')).resolve()
            assert not any(path == p or path.is_relative_to(p) for p in TARGETS), str(path)
        for p in TARGETS:
            command = ['/usr/sbin/lsof', '-nP', '-F', 'pn']
            command += ['+D', str(p)] if p.is_dir() else [str(p)]
            check = subprocess.run(command, capture_output=True, text=True)
            assert check.returncode in (0, 1) and not check.stderr.strip(), check.stderr
            owner = None
            for line in check.stdout.splitlines():
                if line.startswith('p'):
                    owner = int(line[1:])
                elif line.startswith('n'):
                    assert owner == os.getpid(), 'Open file: ' + str(owner) + ' ' + line[1:]
        runtime = (VM / '.vphone-runtime.json').read_bytes()
        running = json.loads(runtime)
        os.kill(running['pid'], 0)
        current = identity(VM / 'Disk.img')
        retained = protected()
        verified = evidence()
        before_free = shutil.disk_usage(ROOT).free
        plan = dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    authorization='User: 按建议清理', targets=[str(p.relative_to(ROOT)) for p in TARGETS],
                    initial=initial, protected=retained, evidenceVerified=verified,
                    currentDisk=current, runtime=running, freeBytesBefore=before_free,
                    inventoryEntries=len(inventory))
        save('plan.json', plan)
        (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(inventory).encode(), mtime=0))
        if not apply:
            print(json.dumps(dict(state='prepared', targets=plan['targets'], inventoryEntries=len(inventory))))
            return
        result = dict(state='in_progress', removed=[], freeBytesBefore=before_free)
        save('result.json', result)
        for p in TARGETS:
            assert identity(p) == initial[str(p)], 'Target changed: ' + str(p)
            if p.is_dir():
                shutil.rmtree(p)
            else:
                p.unlink()
            assert not os.path.lexists(p)
            result['removed'].append(str(p.relative_to(ROOT)))
            save('result.json', result)
            print('Removed ' + str(p.relative_to(ROOT)), flush=True)
        assert protected() == retained, 'Protected history changed'
        assert evidence() == verified
        assert (VM / '.vphone-runtime.json').read_bytes() == runtime
        os.kill(running['pid'], 0)
        now = identity(VM / 'Disk.img')
        assert all(now[k] == current[k] for k in ['dev', 'ino', 'size'])
        result.update(state='completed', freeBytesAfter=shutil.disk_usage(ROOT).free,
                      protectedHistoryUnchanged=True, evidenceVerified=verified,
                      runtimeUnchanged=True, currentDiskIdentityUnchanged=True)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - before_free
        save('result.json', result)
        print(json.dumps(result, ensure_ascii=False))
    finally:
        for fd in handles:
            os.close(fd)


if __name__ == '__main__':
    main()

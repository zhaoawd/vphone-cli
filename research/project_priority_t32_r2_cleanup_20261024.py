"""Execute the explicitly approved 19 priority removals, then retire the old r2 VM."""
import datetime
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile

from project_storage_review_20261024 import compare, sha

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'research/evidence/project-priority-t32-r2-cleanup-20261024'
REVIEW = ROOT / 'research/evidence/project-storage-review-20261024'
VM = ROOT / 'vm-t32-t33-20261018-r2'
PLAN = ROOT / '.build/t32-t33-completion-20261023/origin-identity-acceptance-20261024-r2/offline-plan.json'
PLAN_SHA = 'b98e0a565583ebd57380c5984be62ff0ed491fe499e7357c4d111c8fe5f87230'


def save(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def metadata(path):
    s = path.lstat()
    row = dict(dev=s.st_dev, ino=s.st_ino, mode=s.st_mode, uid=s.st_uid, gid=s.st_gid,
               size=s.st_size, mtime_ns=s.st_mtime_ns, ctime_ns=s.st_ctime_ns, blocks=s.st_blocks)
    if stat.S_ISLNK(s.st_mode):
        row['link'] = os.readlink(path)
    return row


def inventory(target):
    rows = {str(target.relative_to(ROOT)): metadata(target)}
    for parent, dirs, files in os.walk(target, followlinks=False,
                                     onerror=lambda e: (_ for _ in ()).throw(e)):
        if os.path.ismount(parent) or not os.access(parent, os.W_OK | os.X_OK):
            raise RuntimeError('Mounted or unwritable directory: ' + parent)
        for name in dirs + files:
            path = Path(parent) / name
            rows[str(path.relative_to(ROOT))] = metadata(path)
    return rows


def unused(target):
    check = subprocess.run(['/usr/sbin/lsof', '-nP', '-F', 'pn', '+D', str(target)],
                           capture_output=True, text=True)
    if check.returncode not in (0, 1) or check.stderr.strip():
        raise RuntimeError('lsof check failed: ' + check.stderr)
    owner = None
    for line in check.stdout.splitlines():
        if line.startswith('p'):
            owner = int(line[1:])
        elif line.startswith('n') and owner != os.getpid():
            raise RuntimeError(f'Open target by PID {owner}: {line[1:]}')


def runtime_check(targets, label):
    processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,lstart=,command='], text=True)
    relevant = [line for line in processes.splitlines()
                if 'vphone' in line or 'cfw_' in line or 'swift' in line or 'xcodebuild' in line]
    (OUT / (label + '-processes.txt')).write_text('\n'.join(relevant) + '\n')
    for line in processes.splitlines():
        if int(line.split()[0]) == os.getpid():
            continue
        if 'vm-t32-t33-20261018-r2' in line:
            raise RuntimeError('Process refers to retired VM: ' + line)
        if re.search(r'/(?:swift-build|swift-test|swiftc|xcodebuild)(?:\s|$)', line):
            raise RuntimeError('Build process running: ' + line)
    images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
    for entry in images.get('images', []):
        image = Path(entry.get('image-path', '/nonexistent')).resolve()
        if any(image == p or image.is_relative_to(p) for p in targets):
            raise RuntimeError('Attached image: ' + str(image))
        for entity in entry.get('system-entities', []):
            mount = entity.get('mount-point')
            if mount and any(Path(mount).is_relative_to(p) for p in targets):
                raise RuntimeError('Mounted volume under target: ' + mount)
    return [line for line in relevant if '/vphone-vm ' in line]


def disks():
    paths = list(ROOT.glob('vm*/Disk.img'))
    for name in ['.build/t32q-20261024', '.build/t32q-20261024-binding-backup',
                 '.build/t32r-20261023',
                 '.build/t32-t33-completion-20261023/pre-acceptance-backup',
                 '.build/t32-t33-completion-20261023/fresh-library']:
        path = ROOT / name
        if path.exists():
            paths += list(path.rglob('Disk.img'))
    return {str(p.relative_to(ROOT)): {k: metadata(p)[k] for k in ('dev', 'ino', 'size')}
            for p in paths if p != VM / 'Disk.img'}


def archive_vm(rows):
    files = []
    archive_path = OUT / 'retired-r2-metadata.tar.gz'
    with tarfile.open(archive_path, 'w:gz') as archive:
        for name, row in sorted(rows.items()):
            path = ROOT / name
            if (not stat.S_ISREG(row['mode']) or row['size'] > 8 << 20
                    or path.suffix not in ('.json', '.jsonl', '.plist', '.log', '.txt', '.shsh')):
                continue
            files.append(dict(path=name, bytes=row['size'], sha256=sha(path)))
            archive.add(path, arcname=name, recursive=False)
    with tarfile.open(archive_path) as archive:
        if len(archive.getmembers()) != len(files):
            raise RuntimeError('Metadata archive member count differs')
        for row in files:
            with archive.extractfile(row['path']) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != row['sha256']:
                    raise RuntimeError('Metadata archive differs: ' + row['path'])
    save('retired-r2-metadata-manifest.json', dict(files=files, archiveSHA256=sha(archive_path),
         fullDiskBackup=False, scope='Regular JSON/JSONL/plist/log/txt/shsh up to 8 MiB each; cannot restore VM'))
    return len(files)


def main():
    if sys.argv[1:] != ['--apply'] or OUT.exists():
        raise RuntimeError('Use --apply once; preserve any existing execution evidence')
    OUT.mkdir()
    result = dict(state='checking', authorization='清理优先清理的内容，然后清理t32 r2vm',
                  startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), removed=[])
    save('result.json', result)
    handles = []
    try:
        for name, expected in {
            'cache-candidates.json': 'e5a396d0a3933cf1b83bdd63105d2c212c708d5ffea98bd5cdc57a6a464e2419',
            'package-comparison.json': '2fe2c48bfe7223e574a359324507a3da88dd77f858450252c2aa80973b5d6256',
        }.items():
            if sha(REVIEW / name) != expected:
                raise RuntimeError('Approved target assessment changed: ' + name)
        caches = json.loads((REVIEW / 'cache-candidates.json').read_text())
        packages = json.loads((REVIEW / 'package-comparison.json').read_text())
        targets = [ROOT / x['path'] for x in caches] + [ROOT / x['directory'] for x in packages] + [VM]
        if len(caches) != 11 or len(packages) != 8 or len(set(targets)) != 20:
            raise RuntimeError('Unexpected target list')
        if sha(PLAN) != PLAN_SHA:
            raise RuntimeError('Current acceptance plan changed')
        frozen = json.loads(PLAN.read_text())['frozenInputs']
        protected = {str(PLAN): PLAN_SHA, **frozen}
        protected.update({str(ROOT / x['archive']): x['archiveSHA256'] for x in packages})
        for path in targets:
            if path.resolve(strict=True) != path or not path.is_dir():
                raise RuntimeError('Unexpected or linked target: ' + str(path))
            if any(path != other and path.is_relative_to(other) for other in targets):
                raise RuntimeError('Overlapping targets')
            for name in frozen:
                if Path(name).resolve().is_relative_to(path):
                    raise RuntimeError('Frozen input under target: ' + name)
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name in ('.vphone-online-operation.lock', '.firmware-desired.lock'):
            path = VM / name
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        tracked = subprocess.check_output(['git', 'ls-files', '-z', '--',
                                          *[str(p.relative_to(ROOT)) for p in targets]], cwd=ROOT)
        if tracked:
            raise RuntimeError('Tracked files inside targets')
        runtime = runtime_check(targets, 'before')
        inventories = {}
        for path in targets:
            unused(path)
            rows = inventory(path)
            inventories[str(path.relative_to(ROOT))] = rows
            for name, row in rows.items():
                if path != VM and Path(name).name in ('Disk.img', 'guest-postimage.img', '.cfw-history', '.firmware-generations'):
                    raise RuntimeError('VM state under priority cache: ' + name)
                if path == VM and stat.S_ISREG(row['mode']) and Path(name).name in ('Disk.img', 'guest-postimage.img'):
                    fd = os.open(ROOT / name, os.O_RDONLY | os.O_NOFOLLOW)
                    handles.append(fd)
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        comparisons = [compare(ROOT / x['directory'], ROOT / x['archive'], x['archiveSHA256'], frozen)
                       for x in packages]
        save('package-recheck.json', comparisons)
        print('Verified retained archives and 2152 package files', flush=True)
        evidence_base = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023'
        for batch in ('origin-identity-fix-20261024', 'producer-offline-outcome-20261024'):
            manifest = evidence_base / batch / 'manifest.json'
            protected[str(manifest)] = sha(manifest)
            for row in json.loads(manifest.read_text())['files']:
                protected[str(manifest.parent / row['path'])] = row['sha256']
        for name, expected in protected.items():
            if sha(Path(name)) != expected:
                raise RuntimeError('Protected input digest differs: ' + name)
        archive_count = archive_vm(inventories[str(VM.relative_to(ROOT))])
        protected_disks = disks()
        save('protected-before.json', dict(digests=protected, disks=protected_disks, runningVMs=runtime))
        (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(inventories).encode(), mtime=0))
        free_before = shutil.disk_usage(ROOT).free
        save('plan.json', dict(targets=[str(p.relative_to(ROOT)) for p in targets],
             allocatedBytesByTarget={name: sum(r['blocks'] * 512 for r in rows.values())
                                     for name, rows in inventories.items()},
             freeBytesBefore=free_before, metadataFilesArchived=archive_count, fullDiskBackup=False))
        if runtime_check(targets, 'pre-removal') != runtime:
            raise RuntimeError('Running VM process identity changed')
        result.update(state='removing', freeBytesBefore=free_before)
        save('result.json', result)
        for path in targets:
            name = str(path.relative_to(ROOT))
            unused(path)
            if inventory(path) != inventories[name]:
                raise RuntimeError('Target changed during preparation: ' + name)
            shutil.rmtree(path)
            if os.path.lexists(path):
                raise RuntimeError('Target remains: ' + name)
            result['removed'].append(name)
            save('result.json', result)
            print('Removed ' + name, flush=True)
        for name, expected in protected.items():
            if sha(Path(name)) != expected:
                raise RuntimeError('Protected digest changed: ' + name)
        if disks() != protected_disks or runtime_check(targets, 'after') != runtime:
            raise RuntimeError('Other disk or running VM process identity changed')
        if any(os.path.lexists(p) for p in targets):
            raise RuntimeError('Removed target reappeared')
        result.update(state='completed', protectedDigestsVerified=len(protected),
                      frozenInputsVerified=len(frozen), protectedDiskIdentitiesVerified=len(protected_disks),
                      runningVMProcessesUnchanged=True, metadataFilesArchived=archive_count,
                      freeBytesAfter=shutil.disk_usage(ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - free_before
        result['capacity75GiBPassed'] = result['freeBytesAfter'] >= 75 * (1 << 30)
        save('result.json', result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    except Exception as error:
        result.update(state='failed', error=str(error))
        save('result.json', result)
        raise
    finally:
        for fd in handles:
            os.close(fd)


if __name__ == '__main__':
    main()

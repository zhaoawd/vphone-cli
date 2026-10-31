"""Retire the entire t51rt directory after the explicitly requested shutdown."""
import datetime
import fcntl
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / '.build/t51rt'
VM = TARGET / 'lib/t52-v2'
OUT = ROOT / 'research/evidence/t51rt-cleanup-2026-10-24'


def save(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def metadata(path):
    s = path.lstat()
    row = dict(dev=s.st_dev, ino=s.st_ino, mode=s.st_mode, uid=s.st_uid, gid=s.st_gid,
               size=s.st_size, mtime_ns=s.st_mtime_ns, ctime_ns=s.st_ctime_ns, blocks=s.st_blocks)
    if stat.S_ISLNK(s.st_mode):
        row['link'] = os.readlink(path)
    return row


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory():
    rows = {str(TARGET.relative_to(ROOT)): metadata(TARGET)}
    for parent, dirs, files in os.walk(TARGET, followlinks=False,
                                     onerror=lambda e: (_ for _ in ()).throw(e)):
        if os.path.ismount(parent):
            raise RuntimeError('Mounted directory: ' + parent)
        if not os.access(parent, os.W_OK | os.X_OK):
            raise RuntimeError('Unwritable directory: ' + parent)
        for name in dirs + files:
            path = Path(parent) / name
            rows[str(path.relative_to(ROOT))] = metadata(path)
    return rows


def unused():
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-F', 'pn', '+D', str(TARGET)],
                            capture_output=True, text=True)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError('lsof check failed: ' + result.stderr)
    owner = None
    for line in result.stdout.splitlines():
        if line.startswith('p'):
            owner = int(line[1:])
        elif line.startswith('n') and owner != os.getpid():
            raise RuntimeError(f'Target held by PID {owner}: {line[1:]}')
    images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
    for image in images.get('images', []):
        path = Path(image.get('image-path', '/nonexistent')).resolve()
        if path == TARGET or path.is_relative_to(TARGET):
            raise RuntimeError('Attached image under target: ' + str(path))


def other_disks():
    paths = list(ROOT.glob('vm*/Disk.img'))
    paths += [ROOT / '.build/t32r-20261023/Disk.img',
              ROOT / '.build/t32-t33-completion-20261023/fresh-library/t32-t33-file-acceptance-20261023/Disk.img']
    return {str(p.relative_to(ROOT)): {k: metadata(p)[k] for k in ('dev', 'ino', 'size')}
            for p in paths if p.exists()}


def main():
    if sys.argv[1:] != ['--apply'] or (OUT / 'result.json').exists():
        raise RuntimeError('Explicit --apply and no prior deletion result required')
    shutdown = json.loads((OUT / 'shutdown-result.json').read_text())
    if shutdown['state'] != 'shutdown-completed' or not shutdown['hostProcessExited']:
        raise RuntimeError('Normal shutdown required')
    result = dict(state='checking', authorization='Current chat: 先清理.build/t51rt吧，现在没有磁盘可用',
                  startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), removed=False)
    save('result.json', result)
    handles = []
    try:
        if TARGET.resolve(strict=True) != TARGET or list((TARGET / 'lib').iterdir()) != [VM]:
            raise RuntimeError('Unexpected target or VM namespace')
        for path in [TARGET, TARGET / 'lib', VM]:
            if path.resolve(strict=True) != path:
                raise RuntimeError('Linked lock path')
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        processes = subprocess.check_output(['/bin/ps', '-axo', 'pid,ppid,lstart,command'], text=True)
        (OUT / 'processes-before.txt').write_text(processes)
        for pid in [61927, 61974, 61975, 61980]:
            row = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True)
            if row.returncode != 1 or row.stdout.strip():
                raise RuntimeError('Original process still exists or PID reused: ' + str(pid))
        unused()
        tracked = subprocess.check_output(['git', 'ls-files', '-z', '--', '.build/t51rt'], cwd=ROOT)
        if tracked:
            raise RuntimeError('Tracked content under cleanup target')
        before = inventory()
        for name, row in before.items():
            if stat.S_ISREG(row['mode']) and Path(name).name in ('Disk.img', 'guest-postimage.img'):
                fd = os.open(ROOT / name, os.O_RDONLY | os.O_NOFOLLOW)
                handles.append(fd)
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        metadata_rows = []
        with tarfile.open(OUT / 'retired-metadata.tar.gz', 'w:gz') as archive:
            for name, row in sorted(before.items()):
                path = ROOT / name
                if not stat.S_ISREG(row['mode']) or row['size'] > 8 << 20:
                    continue
                if path.suffix not in ('.json', '.jsonl', '.plist', '.log', '.txt', '.shsh'):
                    continue
                sha = digest(path)
                archive.add(path, arcname=name, recursive=False)
                metadata_rows.append(dict(path=name, bytes=row['size'], sha256=sha))
        with tarfile.open(OUT / 'retired-metadata.tar.gz') as archive:
            for row in metadata_rows:
                with archive.extractfile(row['path']) as stream:
                    if hashlib.file_digest(stream, 'sha256').hexdigest() != row['sha256']:
                        raise RuntimeError('Metadata archive differs')
        save('retired-metadata-manifest.json', dict(files=metadata_rows,
             scope='Regular JSON/JSONL/plist/log/txt/shsh files no larger than 8 MiB; no full disks or blobs',
             archiveSHA256=digest(OUT / 'retired-metadata.tar.gz')))
        tools = ROOT / 'research/upstream_integration_2026-10-15/tools/verify_t52_closeout.py'
        spec = importlib.util.spec_from_file_location('t52_evidence', tools)
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        evidence_before = {name: verifier.verify_batch(name) for name in verifier.BATCHES}
        save('evidence-before.json', evidence_before)
        protected = other_disks()
        free_before = shutil.disk_usage(ROOT).free
        save('plan.json', dict(target=str(TARGET.relative_to(ROOT)), inventoryEntries=len(before),
             allocatedBytes=sum(row['blocks'] * 512 for row in before.values()),
             freeBytesBefore=free_before, metadataFilesArchived=len(metadata_rows),
             otherDiskIdentities=protected, fullDisksArchived=False, rollbackPointsRetired=True))
        (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(before).encode(), mtime=0))
        unused()
        if inventory() != before:
            raise RuntimeError('Target changed during preparation')
        result.update(state='removing', freeBytesBefore=free_before)
        save('result.json', result)
        shutil.rmtree(TARGET)
        if os.path.lexists(TARGET):
            raise RuntimeError('Target remains after removal')
        result['removed'] = True
        save('result.json', result)
        evidence_after = {name: verifier.verify_batch(name) for name in verifier.BATCHES}
        save('evidence-after.json', evidence_after)
        if evidence_after != evidence_before or other_disks() != protected:
            raise RuntimeError('Protected evidence or other disk identity changed')
        result.update(state='completed', evidenceFilesVerified=sum(x['filesVerified'] for x in evidence_after.values()),
                      evidenceUnchanged=True, otherDiskIdentitiesUnchanged=True,
                      freeBytesAfter=shutil.disk_usage(ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - free_before
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

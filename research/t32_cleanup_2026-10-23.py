"""Remove only five approved unpacked bundles and one verified duplicate disk."""
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
import tarfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / '.build/t32-t33-completion-20261023'
OUT = ROOT / 'research/evidence/t32-cleanup-2026-10-23'
PACKAGES = [BASE / name for name in ('package', 'package-r2', 'package-r3', 'package-r4', 'package-r5')]
BACKUP = BASE / 'completed-runtime/pre-runtime-backup'
DISK = BACKUP / 'Disk.img'
VM = BASE / 'fresh-library/t32-t33-file-acceptance-20261023'
POSTIMAGE = VM / '.cfw-history/20261023T093802Z-XHDHXIve/guest-postimage.img'
TARGETS = PACKAGES + [DISK]


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def metadata(path):
    s = path.lstat()
    result = dict(dev=s.st_dev, ino=s.st_ino, mode=s.st_mode, uid=s.st_uid, gid=s.st_gid,
                  size=s.st_size, mtime_ns=s.st_mtime_ns, ctime_ns=s.st_ctime_ns, blocks=s.st_blocks)
    if stat.S_ISLNK(s.st_mode):
        result['link'] = os.readlink(path)
    return result


def sha(path, progress=False):
    before = metadata(path)
    digest = hashlib.sha256()
    count = 0
    with path.open('rb') as stream:
        while chunk := stream.read(8 << 20):
            digest.update(chunk)
            count += len(chunk)
            if progress and count % (8 << 30) == 0:
                print(f'Hashed {count // (1 << 30)} GiB: {path.relative_to(ROOT)}', flush=True)
    if metadata(path) != before:
        raise RuntimeError('Changed during hashing: ' + str(path))
    return digest.hexdigest()


def inventory(paths):
    result = {}
    for path in paths:
        result[str(path.relative_to(ROOT))] = metadata(path)
        if path.is_dir() and not path.is_symlink():
            for parent, dirs, files in os.walk(path, followlinks=False,
                                             onerror=lambda e: (_ for _ in ()).throw(e)):
                if os.path.ismount(parent):
                    raise RuntimeError('Mounted directory: ' + parent)
                for name in dirs + files:
                    p = Path(parent) / name
                    result[str(p.relative_to(ROOT))] = metadata(p)
    return result


def unoccupied(path):
    command = ['/usr/sbin/lsof', '-nP', '-F', 'pn']
    command += ['+D', str(path)] if path.is_dir() else [str(path)]
    check = subprocess.run(command, capture_output=True, text=True)
    if check.returncode not in (0, 1) or check.stderr.strip():
        raise RuntimeError('lsof failed: ' + check.stderr)
    owner = None
    for line in check.stdout.splitlines():
        if line.startswith('p'):
            owner = int(line[1:])
        elif line.startswith('n') and owner != os.getpid():
            raise RuntimeError(f'Open target by PID {owner}: {line[1:]}')


def main():
    if sys.argv[1:] != ['--apply']:
        raise RuntimeError('Explicit --apply required')
    OUT.mkdir(exist_ok=False)
    result = dict(state='checking', removed=[], authorization='Current chat: 按建议来',
                  startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
    save('result.json', result)
    handles = []
    try:
        # Directory flock is the product VM exclusion mechanism.
        locks = [VM, ROOT / '.build/t32r-20261023', BACKUP, POSTIMAGE, *TARGETS]
        for path in locks:
            if path.resolve(strict=True) != path or not path.is_relative_to(ROOT):
                raise RuntimeError('Unexpected path or symlink: ' + str(path))
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
        for image in images.get('images', []):
            path = Path(image.get('image-path', '/nonexistent')).resolve()
            if any(path == p or path.is_relative_to(p) for p in [VM, BACKUP, *PACKAGES]):
                raise RuntimeError('Attached image: ' + str(path))
        for path in [*TARGETS, POSTIMAGE]:
            unoccupied(path)
        before = inventory(TARGETS)
        archive_records = []
        for i, package in enumerate(PACKAGES, 1):
            lines = (BASE / f'candidate-build-r{i}.log').read_text().splitlines()
            record = next(json.loads(line) for line in reversed(lines) if line.startswith('{"state":'))
            archive = BASE / (record['version'] + '.tar')
            if archive.resolve(strict=True) != archive:
                raise RuntimeError('Linked archive')
            fd = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            actual = sha(archive)
            if actual != record['archiveSHA256']:
                raise RuntimeError('Archive digest differs')
            seen = set()
            count = 0
            with tarfile.open(archive) as tar:
                for member in tar:
                    parts = Path(member.name).parts
                    if any(part.startswith('._') for part in parts):
                        continue
                    if not parts or parts[0] != 'VPhone.bundle' or '..' in parts:
                        raise RuntimeError('Archive member escapes bundle')
                    if member.name in seen:
                        raise RuntimeError('Duplicate archive member')
                    seen.add(member.name)
                    path = package / member.name
                    info = path.lstat()
                    if member.isfile():
                        if not stat.S_ISREG(info.st_mode) or info.st_size != member.size:
                            raise RuntimeError('Bundle member type/size differs')
                        with tar.extractfile(member) as stream:
                            expected = hashlib.file_digest(stream, 'sha256').hexdigest()
                        if sha(path) != expected or stat.S_IMODE(info.st_mode) != member.mode:
                            raise RuntimeError('Bundle content/mode differs')
                        count += 1
                    elif member.issym():
                        if not path.is_symlink() or os.readlink(path) != member.linkname:
                            raise RuntimeError('Bundle link differs')
                    elif not member.isdir() or not stat.S_ISDIR(info.st_mode):
                        raise RuntimeError('Unsupported archive member')
            actual_names = {str(p.relative_to(package)) for p in (package / 'VPhone.bundle').rglob('*')}
            if actual_names - seen:
                raise RuntimeError('Unarchived bundle members')
            archive_records.append(dict(package=str(package.relative_to(ROOT)),
                                        archive=str(archive.relative_to(ROOT)), sha256=actual,
                                        filesVerified=count))
        backup_manifest = BASE / 'completed-runtime/runtime-backup.json'
        backup = json.loads(backup_manifest.read_text())
        checkpoint = json.loads((POSTIMAGE.parent / 'guest-publication.json').read_text())
        expected = backup['files']['Disk.img']['sha256']
        if expected != checkpoint['imageSHA256'] or DISK.stat().st_size != POSTIMAGE.stat().st_size:
            raise RuntimeError('Disk declarations differ')
        if DISK.stat().st_ino == POSTIMAGE.stat().st_ino:
            raise RuntimeError('Disk names share an inode')
        for path in [DISK, POSTIMAGE]:
            if sha(path, progress=True) != expected:
                raise RuntimeError('Complete disk digest differs: ' + str(path))
        siblings = {}
        for name, row in backup['files'].items():
            if name != 'Disk.img':
                path = BACKUP / name
                if sha(path) != row['sha256']:
                    raise RuntimeError('Backup boot file differs')
                siblings[name] = row['sha256']
        archives = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023'
        verified_evidence = {}
        for name in ['prepared', 'fresh-offline', 'resumed-offline', 'display-runtime-outcome', 'short-runtime-outcome']:
            manifest_path = archives / name / 'manifest.json'
            rows = json.loads(manifest_path.read_text())['files']
            for row in rows:
                path = manifest_path.parent / row['path']
                if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
                    raise RuntimeError('Archived evidence differs')
            verified_evidence[name] = len(rows)
        protected_paths = [VM / '.cfw-history', BASE / 'package-r6', *BASE.glob('*.tar'),
                           BASE / 'pre-acceptance-backup', BASE / 'display-runtime/pre-runtime-backup',
                           backup_manifest, *[BACKUP / name for name in siblings]]
        protected = inventory(protected_paths)
        running = ROOT / '.build/t51rt/lib/t52-v2'
        runtime = (running / '.vphone-runtime.json').read_bytes()
        pid = json.loads(runtime)['pid']
        os.kill(pid, 0)
        running_disk = metadata(running / 'Disk.img')
        for path in TARGETS:
            unoccupied(path)
        if inventory(TARGETS) != before:
            raise RuntimeError('Cleanup target changed during verification')
        free_before = shutil.disk_usage(ROOT).free
        plan = dict(targets=[str(p.relative_to(ROOT)) for p in TARGETS], archives=archive_records,
                    duplicateDiskSHA256=expected, retainedPostimage=str(POSTIMAGE.relative_to(ROOT)),
                    diskBytes=DISK.stat().st_size, retainedBootFiles=siblings,
                    evidenceVerified=verified_evidence, protected=protected,
                    freeBytesBefore=free_before, runningPID=pid,
                    allocatedTargetBytes=sum(row['blocks'] * 512 for row in before.values()))
        save('plan.json', plan)
        (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(before).encode(), mtime=0))
        result.update(state='removing', freeBytesBefore=free_before)
        save('result.json', result)
        for path in TARGETS:
            if metadata(path) != before[str(path.relative_to(ROOT))]:
                raise RuntimeError('Target changed before removal')
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
            if os.path.lexists(path):
                raise RuntimeError('Target remains')
            result['removed'].append(str(path.relative_to(ROOT)))
            save('result.json', result)
            print('Removed ' + str(path.relative_to(ROOT)), flush=True)
        if inventory(protected_paths) != protected:
            raise RuntimeError('Protected files changed')
        if (running / '.vphone-runtime.json').read_bytes() != runtime:
            raise RuntimeError('Running VM record changed')
        os.kill(pid, 0)
        now = metadata(running / 'Disk.img')
        if any(now[k] != running_disk[k] for k in ['dev', 'ino', 'size']):
            raise RuntimeError('Running disk identity changed')
        for name, expected_boot in siblings.items():
            if sha(BACKUP / name) != expected_boot:
                raise RuntimeError('Retained boot file changed')
        result.update(state='completed', protectedUnchanged=True, runningVMUnchanged=True,
                      retainedBootFilesVerified=len(siblings), freeBytesAfter=shutil.disk_usage(ROOT).free,
                      evidenceVerified=verified_evidence)
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

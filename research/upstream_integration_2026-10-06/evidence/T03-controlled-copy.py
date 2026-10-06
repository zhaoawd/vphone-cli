"""T03 acceptance driver: stopped bundle copy; not a product import command."""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import time

CHUNK = 8 * 1024 * 1024
EXCLUDED = {'.vphone-runtime.json', 'vphone.sock'}
# Darwin SDK sys/fcntl.h: fp_flags, reserved, fp_offset, fp_length.
F_PUNCHHOLE = 99
MIN_FREE = 10 * 1024**3


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while block := f.read(CHUNK):
            h.update(block)
    return h.hexdigest()


def inventory(root):
    result = {}
    for p in sorted(root.rglob('*')):
        name = str(p.relative_to(root))
        if name in EXCLUDED:
            continue
        s = p.lstat()
        if not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)):
            raise RuntimeError(f'unsupported file type: {name}')
        result[name] = dict(kind='file' if stat.S_ISREG(s.st_mode) else 'directory',
                            size=s.st_size, mode=stat.S_IMODE(s.st_mode),
                            uid=s.st_uid, gid=s.st_gid, flags=s.st_flags,
                            mtime_ns=s.st_mtime_ns, ctime_ns=s.st_ctime_ns,
                            inode=s.st_ino, allocated=s.st_blocks * 512)
    return result


def free_bytes(path):
    s = os.statvfs(path)
    return s.f_bavail * s.f_frsize


def punch(fd, start, end):
    if end > start:
        fcntl.fcntl(fd, F_PUNCHHOLE, struct.pack('=IIqq', 0, 0, start, end - start))


def copy_file(source, target, meta, guard, threshold, observations):
    srcfd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    dstfd = os.open(target, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
    holes = []
    try:
        size = meta['size']
        os.ftruncate(dstfd, size)
        sparse = size >= 64 * 1024**2 and not meta['flags'] & stat.UF_COMPRESSED
        pos = 0
        while pos < size:
            available = min(free_bytes(guard), free_bytes(target.parent))
            observations['minimum_free_bytes'] = min(observations['minimum_free_bytes'], available)
            if available < threshold + CHUNK:
                raise RuntimeError('free-space guard: stopped before next write')
            if sparse:
                try:
                    data = os.lseek(srcfd, pos, os.SEEK_DATA)
                except OSError as e:
                    if e.errno != errno.ENXIO:
                        raise
                    holes.append((pos, size))
                    break
                if data > pos:
                    holes.append((pos, min(data, size)))
                if data >= size:
                    break
                end = min(os.lseek(srcfd, data, os.SEEK_HOLE), size)
                if end <= data:
                    raise RuntimeError('nonprogressing sparse extent')
                pos = data
            else:
                end = size
            while pos < end:
                available = min(free_bytes(guard), free_bytes(target.parent))
                report_min = observations['minimum_free_bytes']
                observations['minimum_free_bytes'] = min(report_min, available)
                if available < threshold + CHUNK:
                    raise RuntimeError('free-space guard: stopped before next write')
                block = os.pread(srcfd, min(CHUNK, end - pos), pos)
                if not block:
                    raise RuntimeError('short source read')
                if block.count(0) == len(block):
                    holes.append((pos, pos + len(block)))
                else:
                    written = 0
                    while written < len(block):
                        count = os.pwrite(dstfd, block[written:], pos + written)
                        if count <= 0:
                            raise RuntimeError('nonprogressing destination write')
                        written += count
                pos += len(block)
                # APFS may allocate gaps during neighboring writes. Release
                # the preceding hole now, and repeat all holes at file end.
                if holes and holes[-1][1] <= pos:
                    punch(dstfd, *holes[-1])
            for start, stop in holes[-1:]:
                punch(dstfd, start, stop)
        for start, end in holes:
            punch(dstfd, start, end)
        os.fsync(dstfd)
    finally:
        os.close(dstfd)
        os.close(srcfd)
    os.chmod(target, meta['mode'])
    os.utime(target, ns=(meta['mtime_ns'], meta['mtime_ns']))


def copy_bundle(source, destination, report_path, guard, threshold=MIN_FREE):
    source, destination = source.resolve(strict=True), destination.absolute()
    if source == destination or source in destination.parents:
        raise RuntimeError('destination inside source')
    if destination.exists():
        raise RuntimeError('destination already exists; no overwrite')
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = destination.with_name(destination.name + '.staging')
    lockfd = os.open(source, os.O_RDONLY | os.O_DIRECTORY)
    report = {'source': str(source), 'destination': str(destination),
              'excluded': sorted(EXCLUDED), 'started_at': time.time(),
              'minimum_free_bytes': free_bytes(guard), 'status': 'preparing',
              'metadata_limitations': ['ACL and extended attributes are not copied',
                                       'compressed files are copied as ordinary bytes',
                                       'owner/group differences are recorded, not changed']}
    try:
        fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = inventory(source)
        regular = [str(source / n) for n, m in before.items() if m['kind'] == 'file']
        opened = subprocess.run(['/usr/sbin/lsof', '-t', '--', *regular], capture_output=True, text=True)
        if opened.returncode != 1 or opened.stdout.strip():
            raise RuntimeError('source regular files have open handles or lsof failed')
        if free_bytes(guard) < threshold + CHUNK:
            raise RuntimeError('insufficient space before staging')
        stage.mkdir(mode=0o700)
        for name, meta in before.items():
            if meta['kind'] == 'directory':
                (stage / name).mkdir(mode=0o700)
            else:
                copy_file(source / name, stage / name, meta, guard, threshold, report)
                print(json.dumps({'copied': name, 'allocated': (stage / name).stat().st_blocks * 512}), flush=True)
        for name, meta in reversed(list(before.items())):
            if meta['kind'] == 'directory':
                os.chmod(stage / name, meta['mode'])
                os.utime(stage / name, ns=(meta['mtime_ns'], meta['mtime_ns']))
        records = {}
        for name, meta in before.items():
            if meta['kind'] != 'file':
                continue
            source_sha, target_sha = sha(source / name), sha(stage / name)
            if source_sha != target_sha:
                raise RuntimeError(f'ordinary-read SHA mismatch: {name}')
            records[name] = dict(meta, sha256=source_sha,
                                 target_allocated=(stage / name).stat().st_blocks * 512,
                                 target_uid=(stage / name).stat().st_uid,
                                 target_gid=(stage / name).stat().st_gid)
            print(json.dumps({'verified': name, 'sha256': source_sha}), flush=True)
        if inventory(source) != before:
            raise RuntimeError('source metadata changed during copy')
        target = inventory(stage)
        if set(target) != set(before):
            raise RuntimeError('target path set differs')
        for name, meta in before.items():
            fields = ('kind', 'mode', 'mtime_ns', 'size') if meta['kind'] == 'file' else ('kind', 'mode', 'mtime_ns')
            if any(target[name][k] != meta[k] for k in fields):
                raise RuntimeError(f'target metadata mismatch: {name}')
        os.rename(stage, destination)
        report.update(status='verified', files=records, directories={n:m for n,m in before.items() if m['kind']=='directory'})
    except BaseException as e:
        report.update(status='failed', error=f'{type(e).__name__}: {e}', staging=str(stage))
        raise
    finally:
        report['ended_at'] = time.time()
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        os.close(lockfd)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('--guard-volume', type=Path, required=True)
    args = parser.parse_args()
    copy_bundle(args.source, args.destination, args.report, args.guard_volume)

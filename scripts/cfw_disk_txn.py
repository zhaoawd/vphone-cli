#!/usr/bin/env python3
"""CFW disk transaction: install onto a copy of Disk.img, publish by swap.

cfw_install_host.sh holds the VM directory lock and a read-only descriptor on
the original Disk.img (--fd) for its whole run. This helper never opens the
original for writing and never falls back to writing it in place:

  stage    clone the descriptor into WORK_DIR/Disk.img (fclonefileat); when
           cloning fails, make a sparse full copy and require SHA-256 equality
           with the original; when both fail, refuse.
  check    before mount / install: lock, original identity (descriptor and
           name refer to the recorded dev/inode; size and mtime unchanged),
           staged identity, and no process other than this operation holding
           the original.
  publish  the same checks plus no holder of the staged image, then
           renamex_np(RENAME_SWAP): Disk.img becomes the installed image and
           the original moves into WORK_DIR. Nothing is deleted by the swap.
  finish   verify the original (identity and sampled SHA-256 through the
           descriptor), remove an unpublished copy unless --retain-staged or
           still held, and archive WORK_DIR as .cfw-history/<id>. A published
           run keeps the previous disk there as the rollback copy.

Every command records its result in WORK_DIR/transaction.json. Usage:
  cfw_disk_txn.py stage|publish --fd N --owner-pid P VM_DIR WORK_DIR
  cfw_disk_txn.py check --phase NAME --fd N --owner-pid P VM_DIR WORK_DIR
  cfw_disk_txn.py finish --exit-code C [--retain-staged] --fd N --owner-pid P VM_DIR WORK_DIR
"""
import argparse
import ctypes
import datetime
import errno
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vm_lock  # noqa: E402

DISK = 'Disk.img'
RECORD = 'transaction.json'
HISTORY = '.cfw-history'
CHUNK = 8 << 20
ZERO = bytes(CHUNK)
FULL_SAMPLE_LIMIT = 64 << 20
SAMPLE_EDGE = 16 << 20
SAMPLE_WINDOW = 1 << 20
SAMPLE_COUNT = 64
COPY_MARGIN = 2 << 30
AT_FDCWD = -2
RENAME_SWAP = 0x2
RENAME_EXCL = 0x4
PREVIOUS = 'Disk.img.previous'

_libc = ctypes.CDLL(None, use_errno=True)
_libc.fclonefileat.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
_libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]


class Refused(Exception):
    pass


def describe(error):
    if isinstance(error, OSError) and error.errno:
        return f'{errno.errorcode.get(error.errno, error.errno)}: {error.strerror}'
    return str(error)


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


# MARK: - File operations (replaced by the test fault wrapper)

def clone_file(source_fd, destination):
    if _libc.fclonefileat(source_fd, AT_FDCWD, os.fsencode(destination), 0) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def swap_files(first, second):
    if _libc.renamex_np(os.fsencode(first), os.fsencode(second), RENAME_SWAP) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def move_exclusive(source, destination):
    """rename that fails with EEXIST instead of replacing the destination."""
    if _libc.renamex_np(os.fsencode(source), os.fsencode(destination), RENAME_EXCL) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def data_ranges(fd, size):
    """Allocated ranges via SEEK_DATA/SEEK_HOLE; the whole file when unsupported."""
    offset = 0
    while offset < size:
        try:
            start = os.lseek(fd, offset, os.SEEK_DATA)
        except OSError as error:
            if error.errno == errno.ENXIO:
                return
            # HFS+ reports ENOTTY (observed on macOS 27); treat as one data range.
            if error.errno in (errno.EINVAL, errno.ENOTSUP, errno.ENOTTY):
                yield offset, size
                return
            raise
        if start >= size:
            return
        end = min(os.lseek(fd, start, os.SEEK_HOLE), size)
        yield start, end
        offset = end


def feed_zeros(digest, count):
    view = memoryview(ZERO)
    while count > 0:
        step = min(count, CHUNK)
        digest.update(view[:step])
        count -= step


def read_exact(fd, count, offset):
    data = os.pread(fd, count, offset)
    if len(data) != count:
        raise OSError(errno.EIO, f'short read at offset {offset}')
    return data


def walk(fd, size, digest, visit=None):
    """Feed the whole content (holes as zeros) to digest; visit each data chunk."""
    position = 0
    for start, end in data_ranges(fd, size):
        feed_zeros(digest, start - position)
        offset = start
        while offset < end:
            data = read_exact(fd, min(CHUNK, end - offset), offset)
            digest.update(data)
            if visit:
                visit(data, offset)
            offset += len(data)
        position = end
    feed_zeros(digest, size - position)


def digest_fd(fd, size):
    digest = hashlib.sha256()
    walk(fd, size, digest)
    return digest.hexdigest()


def digest_path(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        return digest_fd(fd, os.fstat(fd).st_size)
    finally:
        os.close(fd)


def copy_file(source_fd, destination, size):
    """Sparse full copy; returns the SHA-256 of the source as read."""
    out = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)

    def write(data, offset):
        if data == ZERO[:len(data)]:
            return  # left as a hole; ftruncate below fixes the length
        view = memoryview(data)
        while view:
            written = os.pwrite(out, view, offset)
            view, offset = view[written:], offset + written

    try:
        digest = hashlib.sha256()
        walk(source_fd, size, digest, write)
        os.ftruncate(out, size)
        os.fsync(out)
        return digest.hexdigest()
    except BaseException:
        os.close(out)
        out = -1
        os.unlink(destination)
        raise
    finally:
        if out >= 0:
            os.close(out)


def sample_digest(fd, size):
    """Full SHA-256 up to 64 MiB; otherwise head, tail and 64 spaced windows."""
    if size <= FULL_SAMPLE_LIMIT:
        return {'kind': 'full', 'sha256': digest_fd(fd, size)}
    windows = [(0, SAMPLE_EDGE), (size - SAMPLE_EDGE, SAMPLE_EDGE)]
    stride = (size - SAMPLE_WINDOW) // (SAMPLE_COUNT - 1)
    windows += [(index * stride, SAMPLE_WINDOW) for index in range(SAMPLE_COUNT)]
    digest = hashlib.sha256()
    for offset, count in windows:
        digest.update(f'{offset}:{count}\0'.encode())
        digest.update(read_exact(fd, count, offset))
    return {'kind': f'sampled:{len(windows)}', 'sha256': digest.hexdigest()}


# MARK: - Records

def identity(info):
    return {'dev': info.st_dev, 'ino': info.st_ino, 'size': info.st_size, 'mtime_ns': info.st_mtime_ns,
            'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid,
            'blocks': info.st_blocks}


def load_record(work):
    path = work / RECORD
    if not path.exists():
        return None
    return json.loads(path.read_text())


def save_record(directory, record):
    temporary = directory / (RECORD + '.tmp')
    with open(temporary, 'w') as stream:
        json.dump(record, stream, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, directory / RECORD)


# MARK: - Checks

def holders(path, owner_pid):
    """PIDs with path open, excluding this operation.

    The driver (owner_pid) holds the original's descriptor; this helper and,
    under a command substitution, the driver's forked subshell (the parent)
    inherit it. No other process is excluded.
    """
    result = subprocess.run(['lsof', '-t', '--', str(path)], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise Refused(f'lsof failed for {path}: {result.stderr.strip()}')
    pids = {int(line) for line in result.stdout.split() if line.isdigit()}
    own = {owner_pid, os.getpid()}
    if parent_of(os.getppid()) == owner_pid:
        own.add(os.getppid())
    return sorted(pids - own)


def parent_of(pid):
    result = subprocess.run(['ps', '-o', 'ppid=', '-p', str(pid)], capture_output=True, text=True)
    text = result.stdout.strip()
    return int(text) if text.isdigit() else None


def require_lock(vm):
    try:
        vm_lock.check_inherited(vm)
    except (OSError, ValueError) as error:
        raise Refused(f'VM lock not held by this operation: {describe(error)}')


def require_original(fd, vm, expected):
    held = os.fstat(fd)
    if (held.st_dev, held.st_ino) != (expected['dev'], expected['ino']):
        raise Refused('the held descriptor does not refer to the recorded original')
    if (held.st_size, held.st_mtime_ns) != (expected['size'], expected['mtime_ns']):
        raise Refused(f'the original changed: size {expected["size"]} -> {held.st_size}, '
                      f'mtime_ns {expected["mtime_ns"]} -> {held.st_mtime_ns}')
    try:
        named = os.lstat(vm / DISK)
    except FileNotFoundError:
        raise Refused(f'{vm / DISK} no longer exists')
    if not stat.S_ISREG(named.st_mode) or (named.st_dev, named.st_ino) != (held.st_dev, held.st_ino):
        raise Refused(f'{vm / DISK} no longer refers to the original (inode {held.st_ino} -> {named.st_ino})')


def require_staged(work, expected):
    try:
        info = os.lstat(work / DISK)
    except FileNotFoundError:
        raise Refused(f'staged image {work / DISK} is missing')
    if not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) != (expected['dev'], expected['ino']):
        raise Refused(f'staged image {work / DISK} was replaced')


def require_unheld(path, owner_pid, what):
    pids = holders(path, owner_pid)
    if pids:
        raise Refused(f'{what} {path} is open in process(es) {", ".join(map(str, pids))}; stop the VM or that process first')


def run_checks(phase, args, record):
    """Raise Refused('<phase> check: ...'); record the failure or the pass."""
    vm, work = args.vm, args.work
    try:
        require_lock(vm)
        require_original(args.fd, vm, record['original'])
        require_staged(work, record['staged'])
        require_unheld(vm / DISK, args.owner_pid, 'original disk')
        if phase == 'pre-publish':
            require_unheld(work / DISK, args.owner_pid, 'staged image')
    except (Refused, OSError) as error:
        record['failure'] = f'{phase} check: {describe(error)}'
        save_record(work, record)
        raise Refused(record['failure'])
    record.setdefault('checks', []).append({'phase': phase, 'at': now(), 'result': 'passed'})
    save_record(work, record)


# MARK: - Commands

def stage(args):
    vm, work, fd = args.vm, args.work, args.fd
    held = os.fstat(fd)
    named = os.lstat(vm / DISK)
    if not stat.S_ISREG(held.st_mode) or not stat.S_ISREG(named.st_mode) \
            or (named.st_dev, named.st_ino) != (held.st_dev, held.st_ino):
        raise Refused(f'{vm / DISK} is not the regular file held by this operation')
    work_info = os.lstat(work)
    if not stat.S_ISDIR(work_info.st_mode) or work.parent != vm or os.listdir(work):
        raise Refused(f'work directory {work} must be an empty directory inside {vm}')
    record = {'version': 1, 'id': f'{datetime.datetime.now(datetime.timezone.utc):%Y%m%dT%H%M%SZ}-{work.name.rsplit(".", 1)[-1]}',
              'vm': str(vm), 'started_at': now(), 'status': 'staging',
              'original': identity(held), 'method': None, 'clone_error': None, 'copy': None,
              'staged': None, 'checks': [], 'failure': None}
    record['original']['sample'] = sample_digest(fd, held.st_size)
    save_record(work, record)
    destination = work / DISK
    try:
        require_lock(vm)
        require_unheld(vm / DISK, args.owner_pid, 'original disk')
        try:
            clone_file(fd, destination)
        except OSError as error:
            if error.errno == errno.EEXIST:
                raise Refused(f'staged image {destination} already exists')
            record['clone_error'] = errno.errorcode.get(error.errno, str(error.errno))
            print(f'[*] APFS clone unavailable ({describe(error)}); making a verified full copy', file=sys.stderr)
            stage_copy(args, record, held, destination)
        else:
            record['method'] = 'clone'
            if os.lstat(destination).st_size != held.st_size or \
                    sample_digest_path(destination) != record['original']['sample']:
                os.unlink(destination)
                raise Refused('clone verification failed: sampled content differs from the original')
        set_owner_and_mode(destination, record['original'])
        require_original(fd, vm, record['original'])
        record['staged'] = identity(os.lstat(destination))
        record['status'] = 'staged'
        record['checks'].append({'phase': 'stage', 'at': now(), 'result': 'passed'})
        save_record(work, record)
        print(destination)
        return 0
    except BaseException as error:
        record['failure'] = f'stage: {describe(error)}'
        save_record(work, record)
        raise


def sample_digest_path(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        return sample_digest(fd, os.fstat(fd).st_size)
    finally:
        os.close(fd)


def stage_copy(args, record, held, destination):
    if os.path.lexists(destination):
        raise Refused(f'staged image {destination} already exists after a failed clone')
    # Clone fails only off APFS; those volumes (HFS+, exFAT) may not keep holes,
    # so require the logical size, not the original's allocation.
    volume = os.statvfs(args.work)
    available = volume.f_bavail * volume.f_frsize
    needed = held.st_size + COPY_MARGIN
    if available < needed:
        raise Refused(f'full copy refused: {available} bytes free, {needed} required (disk size + 2 GiB)')
    try:
        source_digest = copy_file(args.fd, destination, held.st_size)
    except OSError as error:
        raise Refused(f'clone failed ({record["clone_error"]}) and full copy failed ({describe(error)})')
    record['method'] = 'copy'
    copy_digest = digest_path(destination)
    record['copy'] = {'source_sha256': source_digest, 'copy_sha256': copy_digest}
    if copy_digest != source_digest:
        os.unlink(destination)
        raise Refused(f'copy verification failed: source SHA-256 {source_digest}, copy SHA-256 {copy_digest}')


def set_owner_and_mode(path, original):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if (info.st_uid, info.st_gid) != (original['uid'], original['gid']):
            os.fchown(fd, original['uid'], original['gid'])
        os.fchmod(fd, original['mode'] & 0o777)
    finally:
        os.close(fd)


def staged_record(work):
    record = load_record(work)
    if not record or record.get('status') != 'staged':
        raise Refused(f'no staged transaction in {work}')
    return record


def check(args):
    run_checks(args.phase, args, staged_record(args.work))
    return 0


def publish_by_exclusive_rename(args, record):
    """Fallback where RENAME_SWAP is unsupported (HFS+): two renames, no replace.

    Disk.img is moved into WORK_DIR, then the staged image is moved to the free
    name with RENAME_EXCL. Disk.img is absent between the two renames; the VM
    lock keeps cooperating tools out, and neither step can replace or delete a
    file. A failure moves the original back (again with RENAME_EXCL).
    """
    original, staged, previous = args.vm / DISK, args.work / DISK, args.work / PREVIOUS
    move_exclusive(original, previous)
    moved = os.lstat(previous)
    if (moved.st_dev, moved.st_ino) != (record['original']['dev'], record['original']['ino']):
        move_exclusive(previous, original)
        raise Refused('Disk.img changed while publishing; it was moved back and nothing was published')
    try:
        move_exclusive(staged, original)
    except OSError as error:
        try:
            move_exclusive(previous, original)
        except OSError as restore:
            raise Refused(f'publish failed ({describe(error)}) and the original could not be moved back '
                          f'({describe(restore)}); the original is intact at {previous}')
        raise Refused(f'publish (RENAME_EXCL) failed: {describe(error)}; the original was moved back')
    try:
        move_exclusive(previous, staged)  # same layout as the swap: WORK_DIR/Disk.img is the previous disk
    except OSError as error:
        print(f'[!] previous disk kept as {previous}: {describe(error)}', file=sys.stderr)


def publish(args):
    record = staged_record(args.work)
    run_checks('pre-publish', args, record)
    # Keep the renames and the record write together; a signal received here
    # is delivered after the record is saved (finish also reconciles by identity).
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
    try:
        try:
            try:
                swap_files(args.work / DISK, args.vm / DISK)
                record['publish_method'] = 'renamex_np RENAME_SWAP'
            except OSError as error:
                if error.errno not in (errno.ENOTSUP, errno.EINVAL):
                    raise Refused(f'renamex_np RENAME_SWAP failed: {describe(error)}')
                record['swap_error'] = errno.errorcode.get(error.errno, str(error.errno))
                print(f'[*] RENAME_SWAP unsupported here ({describe(error)}); publishing by exclusive renames',
                      file=sys.stderr)
                publish_by_exclusive_rename(args, record)
                record['publish_method'] = 'renamex_np RENAME_EXCL (two steps)'
        except (Refused, OSError) as error:
            record['failure'] = f'publish: {describe(error)}'
            save_record(args.work, record)
            raise Refused(record['failure'])
        record['status'] = 'published'
        record['published_at'] = now()
        published = os.lstat(args.vm / DISK)
        previous = args.work / DISK if os.path.lexists(args.work / DISK) else args.work / PREVIOUS
        retained = os.lstat(previous)
        record['previous_disk'] = previous.name
        record['after_swap'] = {
            'published_is_staged': (published.st_dev, published.st_ino) == (record['staged']['dev'], record['staged']['ino']),
            'previous_is_original': (retained.st_dev, retained.st_ino) == (record['original']['dev'], record['original']['ino']),
        }
        save_record(args.work, record)
    finally:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
    if not all(record['after_swap'].values()):
        print(f'[!] unexpected identities after swap: {record["after_swap"]}', file=sys.stderr)
    return 0


def verify_original(fd, record):
    original = record.get('original')
    if not original:
        return {'unchanged': None, 'detail': 'no original identity recorded'}
    held = os.fstat(fd)
    problems = []
    if (held.st_dev, held.st_ino) != (original['dev'], original['ino']):
        problems.append('descriptor identity differs')
    if (held.st_size, held.st_mtime_ns) != (original['size'], original['mtime_ns']):
        problems.append('size or mtime changed')
    sample = sample_digest(fd, held.st_size)
    if sample != original['sample']:
        problems.append(f'{sample["kind"]} SHA-256 differs')
    return {'unchanged': not problems, 'detail': '; '.join(problems) or
            f'dev/inode/size/mtime equal; {sample["kind"]} SHA-256 equal', 'checked_at': now()}


def is_same(path, expected):
    if not expected:
        return False
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return False
    return (info.st_dev, info.st_ino) == (expected['dev'], expected['ino'])


def finish(args):
    vm, work = args.vm, args.work
    record = load_record(work) or {'version': 1, 'id': f'{datetime.datetime.now(datetime.timezone.utc):%Y%m%dT%H%M%SZ}-{work.name.rsplit(".", 1)[-1]}',
                                    'vm': str(vm), 'status': 'failed', 'failure': 'no transaction record'}
    original, staged_id = record.get('original'), record.get('staged')
    staged, previous = work / DISK, work / PREVIOUS
    published = record.get('status') == 'published'
    # Decide from identities, not only from the record: an interrupt can land
    # between a completed rename and the record write.
    if not published and staged_id and is_same(vm / DISK, staged_id):
        published = True
        record['status'] = 'published'
        record['note'] = 'publication completed before its record was written'
        if is_same(previous, original) and not os.path.lexists(staged):
            move_exclusive(previous, staged)
    if not published and original and is_same(previous, original) and not os.path.lexists(vm / DISK):
        move_exclusive(previous, vm / DISK)
        record['note'] = 'original moved back to Disk.img after an interrupted publication'
    record['exit_code'] = args.exit_code
    if not published:
        record['status'] = 'failed'
        record['failure'] = record.get('failure') or f'install step exited with status {args.exit_code}'
    record['original_check'] = verify_original(args.fd, record)
    record['staged_retained'] = False
    if not published and os.path.lexists(staged):
        # Delete only the staged image: never the original's inode, never an
        # unidentified file once a staged identity was recorded.
        ours = not is_same(staged, original) and (is_same(staged, staged_id) if staged_id else True)
        busy = [] if args.retain_staged or not ours else holders(staged, args.owner_pid)
        if args.retain_staged or busy or not ours:
            record['staged_retained'] = True
            record['staged_retained_reason'] = ('mount cleanup incomplete' if args.retain_staged
                                                else f'open in {busy}' if busy else 'not the recorded staged image')
        else:
            os.unlink(staged)
            record['staged_removed'] = True
    record['finished_at'] = now()
    location = work
    if not record['staged_retained']:
        history = vm / HISTORY
        try:
            info = os.lstat(history)
            if not stat.S_ISDIR(info.st_mode):
                raise Refused(f'{history} is not a directory')
        except FileNotFoundError:
            os.mkdir(history, 0o755)
        location = history / record['id']
        os.rename(work, location)
    record['location'] = str(location)
    save_record(location, record)
    unchanged = record['original_check']['unchanged']
    if published:
        print(f'[*] previous Disk.img retained as {location / DISK}', file=sys.stderr)
    else:
        print(f'[-] CFW install did not change {vm / DISK}; record: {location / RECORD}', file=sys.stderr)
        if record['staged_retained']:
            print(f'[-] staged image retained in {location} ({record["staged_retained_reason"]}); '
                  'detach it, then remove that directory', file=sys.stderr)
    if unchanged is False:
        print(f'[-] original Disk.img check failed: {record["original_check"]["detail"]}', file=sys.stderr)
    print(location)
    return 0 if unchanged is not False else 3


def main(argv):
    parser = argparse.ArgumentParser(prog='cfw_disk_txn.py')
    parser.add_argument('command', choices=('stage', 'check', 'publish', 'finish'))
    parser.add_argument('--fd', type=int, required=True)
    parser.add_argument('--owner-pid', type=int, required=True)
    parser.add_argument('--phase', choices=('pre-mount', 'pre-install'))
    parser.add_argument('--exit-code', type=int, default=1)
    parser.add_argument('--retain-staged', action='store_true')
    parser.add_argument('vm', type=Path)
    parser.add_argument('work', type=Path)
    args = parser.parse_args(argv)
    if args.command == 'check' and not args.phase:
        parser.error('check requires --phase')
    try:
        args.vm = args.vm.resolve(strict=True)
        args.work = args.work.resolve(strict=True)
        return {'stage': stage, 'check': check, 'publish': publish, 'finish': finish}[args.command](args)
    except (Refused, OSError) as error:
        print(f'[-] CFW disk {args.command}: {describe(error)}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

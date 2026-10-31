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
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vm_lock  # noqa: E402
import cfw_guest_evidence as guest_evidence  # noqa: E402
# Hole-aware ranges; a decmpfs file, an ENOTTY/ENXIO/other seek error is read in
# full, never taken for zeros (scripts/sparse_file.py, shared with
# tools/apfs_snap_rename.py).
from sparse_file import data_ranges  # noqa: E402,F401

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
    try: raw = guest_evidence.read(path)
    except FileNotFoundError: return None
    record = json.loads(raw)
    if not isinstance(record, dict) or type(record.get('version')) is not int or record['version'] not in (1, 2, 3, 4, 5):
        raise Refused('unsupported CFW journal version')
    if record['version'] < 3 and ('guestEvidenceRequired' in record or 'guestEvidenceSHA256' in record):
        raise Refused('guest evidence requires a v3/v4 CFW journal; old records permit recovery only')
    if record['version'] in (2, 3, 4, 5) and record.get('provenanceMode') != 'required':
        raise Refused('CFW journal requires Undo provenance')
    if record['version'] in (3, 4, 5) and record.get('guestEvidenceRequired') is not True:
        raise Refused('CFW journal v3/v4 requires sealed guest evidence')
    if (record['version'] in (4, 5)) != (record.get('runtimeImageEvidenceRequired') is True):
        raise Refused('CFW runtime evidence requirement differs from journal version')
    if 'fileOriginalsSHA256' in record and (record['version']!=5 or not isinstance(record['fileOriginalsSHA256'],str)
            or not guest_evidence.DIGEST.fullmatch(record['fileOriginalsSHA256'])):
        raise Refused('File original catalog requires a v5 sealed digest')
    if record.get('operation')=='guest-component-undo-v2' and record['version']!=5:
        raise Refused('Component Undo requires a v5 journal')
    return record


def save_record(directory, record):
    fd, temporary = tempfile.mkstemp(prefix='.transaction-', dir=directory)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(record, stream, indent=2, sort_keys=True)
            stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, directory / RECORD)
        guest_evidence.sync_directory(directory)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


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
        if record.get('vm') != str(vm): raise Refused('CFW journal belongs to another VM')
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


# MARK: - Private mount workspace

def make_mount_directory(parent):
    """Create scratch beneath a root-owned private or sticky directory.

    The caller is root in the host driver. Tests use the invoking uid and
    disposable parents; no ownership is changed by this function.
    """
    parent = Path(parent)
    if not parent.is_absolute() or parent.is_symlink():
        raise Refused('CFW work parent must be an absolute directory without a symlink')
    fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        mode = stat.S_IMODE(info.st_mode)
        if info.st_uid != os.geteuid() or not (mode & 0o077 == 0 or mode & 0o1777 == 0o1777):
            raise Refused('CFW work parent must be owned by the effective uid and private or sticky')
        # mkdirat keeps creation on the checked parent, even if its name moves.
        import secrets
        name = '.cfw_mount.' + secrets.token_hex(12)
        os.mkdir(name, 0o700, dir_fd=fd)
        created = Path(os.path.realpath(parent)) / name
        actual, named = os.stat(name, dir_fd=fd, follow_symlinks=False), os.lstat(created)
        if (actual.st_dev, actual.st_ino) != (named.st_dev, named.st_ino):
            raise Refused('CFW work parent changed during directory creation')
        return created
    finally:
        os.close(fd)


def mount_identity(root):
    root = Path(root)
    info = os.lstat(root)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise Refused('CFW mount root must be a private directory owned by the effective uid')
    if root != root.resolve(strict=True):
        raise Refused('CFW mount root contains a symlink')
    return {'path': str(root), 'dev': info.st_dev, 'ino': info.st_ino, 'uid': info.st_uid}


def require_mount_root(vm, work, root):
    """Only the journal-bound external root may extend private_path's scope."""
    if work.parent != vm or not work.name.startswith('.cfw_disk.') or work.is_symlink():
        raise Refused('CFW mount evidence is outside this VM transaction')
    record = load_record(work)
    if not record or record.get('vm') != str(vm) or record.get('mountRoot') != mount_identity(root):
        raise Refused('CFW mount root differs from the transaction journal')
    return root


def require_free_space(paths, minimum=50 << 30):
    """statvfs works on external volumes without Foundation capacity metadata."""
    seen = set()
    for path in paths:
        try:
            device = os.stat(path).st_dev
            if device in seen:
                continue
            seen.add(device)
            volume = os.statvfs(path)
            available = volume.f_bavail * volume.f_frsize
        except OSError as error:
            raise Refused(f'CFW free space is unverified at {path}: {describe(error)}') from error
        if available < minimum:
            raise Refused(f'CFW workspace at {path}: {available} bytes free, {minimum} required')


def bind_mount(args):
    record = staged_record(args.work)
    run_checks('pre-publish', args, record)
    record['mountRoot'] = mount_identity(Path(os.environ['CFW_HOST_MNT']))
    save_record(args.work, record)
    return 0


# MARK: - Commands

def stage(args):
    vm, work, fd = args.vm, args.work, args.fd
    held = os.fstat(fd)
    named = os.lstat(vm / DISK)
    if not stat.S_ISREG(held.st_mode) or not stat.S_ISREG(named.st_mode) \
            or (named.st_dev, named.st_ino) != (held.st_dev, held.st_ino):
        raise Refused(f'{vm / DISK} is not the regular file held by this operation')
    work_info = os.lstat(work)
    if not stat.S_ISDIR(work_info.st_mode) or work.parent != vm or work_info.st_dev != held.st_dev or os.listdir(work):
        raise Refused(f'work directory {work} must be an empty directory inside {vm}')
    record = {'version': 2, 'provenanceMode': 'required', 'id': f'{datetime.datetime.now(datetime.timezone.utc):%Y%m%dT%H%M%SZ}-{work.name.rsplit(".", 1)[-1]}',
              'vm': str(vm), 'started_at': now(), 'status': 'staging',
              'original': identity(held), 'method': None, 'clone_error': None, 'copy': None,
              'staged': None, 'checks': [], 'failure': None}
    if getattr(args, 'guest_evidence', False):
        record.update(version=5, guestEvidenceRequired=True, runtimeImageEvidenceRequired=True)
    if os.environ.get('CFW_HOST_MNT'):
        mount = Path(os.environ['CFW_HOST_MNT'])
        # Existing VM-local roots retain their original path policy. Only an
        # external root extends that policy and needs a journal identity.
        if mount.resolve(strict=True).parent != vm.resolve(strict=True):
            record['mountRoot'] = mount_identity(mount)
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


def current_guest_plan():
    from patchers import plan_gate
    plan = plan_gate.from_environment()
    # Writers and their mounts have already been released. Requalify the plan,
    # inherited VM lock and private evidence path without requiring a live mount.
    vm = Path(plan.context['vmDirectory'])
    require_lock(vm)
    sink = plan_gate.private_path(plan, os.environ['VPHONE_GUEST_EVIDENCE'])
    if sink.parent.parent != vm or not sink.parent.name.startswith('.cfw_disk.') or sink.name != guest_evidence.OPERATIONS:
        raise Refused('guest seal evidence path differs from the private transaction')
    return plan


def seal(args):
    record = staged_record(args.work)
    if record.get('version') not in (3, 4, 5):
        raise Refused('guest seal requires v3/v4; old records permit recovery only')
    if not record.get('guestEvidenceRequired') or record.get('guestEvidenceSHA256'):
        raise Refused('guest seal requires an unsealed v3/v4 CFW transaction')
    run_checks('pre-publish', args, record)
    if Path(os.environ['VPHONE_GUEST_EVIDENCE']) != args.work / guest_evidence.OPERATIONS:
        raise Refused('guest evidence belongs to another transaction work directory')
    plan = current_guest_plan()
    if plan.context['vmDirectory'] != str(args.vm): raise Refused('guest plan belongs to another VM')
    try:
        image_sha = checked_image_digest(args.work / DISK)
        checkpoint = guest_evidence.prepare(args.work, record, plan, image_sha)
        run_checks('pre-publish', args, record)
        fresh = current_guest_plan()
        if fresh.record_json != plan.record_json or fresh.context_json != plan.context_json:
            raise Refused('qualified guest plan changed during seal')
        record['guestEvidenceSHA256'] = checkpoint
        record['sealed_at'] = now()
        save_record(args.work, record)
        verify_guest_evidence(args.work, record, args.work / DISK)
    except (ValueError, OSError, KeyError) as error:
        raise Refused('guest evidence seal: ' + describe(error)) from error
    return 0


def verify_guest_evidence(work, record, image, *, allow_runtime=False, check_operation=True):
    if record.get('version') in (3, 4, 5):
        try:
            fd = os.open(image, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                before = os.fstat(fd)
                value = guest_evidence.verify(work, record, image, checked_image_digest(image),
                    allow_runtime=allow_runtime, check_operation=check_operation)
                guest_evidence.unchanged(image, fd, before)
                return value
            finally: os.close(fd)
        except (ValueError, OSError, KeyError) as error:
            raise Refused('guest publication evidence: ' + describe(error)) from error
    return None


def checked_image_digest(image):
    fd = os.open(image, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        os.fsync(fd)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise Refused('guest image is not a private regular file')
        value = digest_fd(fd, before.st_size)
        guest_evidence.unchanged(image, fd, before)
        return value
    finally: os.close(fd)


def publish_by_exclusive_rename(args, record):
    """Fallback where RENAME_SWAP is unsupported (HFS+): two renames, no replace.

    Disk.img is moved into WORK_DIR, then the staged image is moved to the free
    name with RENAME_EXCL. Disk.img is absent between the two renames; the VM
    lock keeps cooperating tools out, and neither step can replace or delete a
    file. A failure moves the original back (again with RENAME_EXCL).
    """
    original, staged, previous = args.vm / DISK, args.work / DISK, args.work / PREVIOUS
    move_exclusive(original, previous)
    if record.get('version') in (2, 3, 4, 5):
        guest_evidence.sync_directory(args.vm); guest_evidence.sync_directory(args.work)
    moved = os.lstat(previous)
    if (moved.st_dev, moved.st_ino) != (record['original']['dev'], record['original']['ino']):
        move_exclusive(previous, original)
        raise Refused('Disk.img changed while publishing; it was moved back and nothing was published')
    try:
        move_exclusive(staged, original)
        if record.get('version') in (2, 3, 4, 5):
            guest_evidence.sync_directory(args.vm); guest_evidence.sync_directory(args.work)
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
    from patchers.undo_provenance import verify_publication
    try:
        verify_publication(args.work,record)
    except (ValueError,KeyError,OSError) as error:
        raise Refused('Undo provenance publication refused: ' + str(error)) from error
    try:
        proof = verify_guest_evidence(args.work, record, args.work / DISK)
        if proof is not None:
            if Path(os.environ['VPHONE_GUEST_EVIDENCE']) != args.work / guest_evidence.OPERATIONS:
                raise Refused('guest evidence belongs to another transaction work directory')
            plan = current_guest_plan()
            if plan.raw_sha256 != proof['desiredSHA256'] or plan.context['vmDirectory'] != record['vm']:
                raise Refused('qualified guest plan changed before publication')
    except (Refused, ValueError, OSError, KeyError) as error:
        record['failure'] = 'publish qualification: ' + describe(error)
        save_record(args.work, record)
        raise Refused(record['failure']) from error
    # Source/effect qualification can be lengthy; recheck disk holders and
    # original/staged identities after that work, before publication.
    run_checks('pre-publish-qualified', args, record)
    if record.get('operation') is not None:
        from patchers import guest_undo
        request = guest_undo.request_for(args.work, record)
        current, before, _ = guest_undo.check_origin(args.vm, request['origin'])
        if current != before: raise Refused('guest origin changed before disk publication')
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
        if record.get('operation') is not None:
            from patchers.guest_undo import publish_origin
            publish_origin(args.work, record)
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
        if record.get('version') in (2, 3, 4, 5):
            guest_evidence.sync_directory(args.vm)
            guest_evidence.sync_directory(args.work)
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
    if record.get('vm') != str(vm): raise Refused('CFW finish journal belongs to another VM')
    staged, previous = work / DISK, work / PREVIOUS
    published = record.get('status') == 'published'
    require_lock(vm)
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
    if published:
        try:
            if record.get('version') in (2, 3, 4, 5) and sum(is_same(path, original) for path in (staged, previous)) != 1:
                raise Refused('published guest has no unique retained original disk')
            verify_guest_evidence(work, record, vm / DISK)
        except Refused as error:
            record['status'] = 'publication-uncertain'
            record['failure'] = str(error)
            save_record(work, record)
            raise
    record['exit_code'] = args.exit_code
    if not published:
        record['status'] = 'failed'
        record['failure'] = record.get('failure') or f'install step exited with status {args.exit_code}'
    record['original_check'] = verify_original(args.fd, record)
    if record.get('version') in (2, 3, 4, 5) and record['original_check']['unchanged'] is False:
        record['status'] = 'publication-uncertain'
        record['failure'] = 'original disk content changed; retain both images and evidence'
        save_record(work, record)
        raise Refused(record['failure'])
    if published and record.get('operation') is not None:
        from patchers.guest_undo import publish_origin
        try: publish_origin(work, record)
        except (ValueError, OSError) as error:
            record['status'] = 'publication-uncertain'; record['failure'] = str(error)
            save_record(work, record)
            raise Refused(str(error)) from error
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
        if Path(record['id']).name != record['id'] or record['id'] in ('.', '..'):
            raise Refused('invalid CFW history transaction ID')
        if os.path.lexists(location): raise Refused('CFW history transaction already exists')
        # The directory rename is the committed-history boundary. Persist all
        # completion evidence before crossing it so a crash before the final
        # informational write cannot strand an otherwise complete publication.
        record['location'] = str(location)
        save_record(work, record)
        os.rename(work, location)
        guest_evidence.sync_directory(history)
        guest_evidence.sync_directory(vm)
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


def committed_guest_evidence(vm, image=None, ignore_work=None):
    """Resolve the unique sealed publication associated with the current disk."""
    require_lock(vm)
    image = image if image is not None else vm / DISK
    for work in vm.glob('.cfw_disk.*'):
        if work == ignore_work: continue
        if work.is_symlink() or not work.is_dir(): raise Refused('unknown CFW staging entry')
        pending = load_record(work)
        if pending and (pending.get('status') == 'publication-uncertain' or is_same(image, pending.get('staged'))):
            raise Refused('CFW publication requires finish/recovery before evidence inspection')
    history = vm / HISTORY
    if not os.path.lexists(history): return None
    if history.is_symlink() or not history.is_dir(): raise Refused('invalid CFW history directory')
    candidates = []
    for archive in history.iterdir():
        if archive.is_symlink() or not archive.is_dir(): raise Refused('invalid CFW history entry')
        record = load_record(archive)
        if not record or record.get('version') not in (3, 4, 5) or not is_same(image, record.get('staged')): continue
        if (record.get('status') != 'published' or record.get('id') != archive.name or record.get('vm') != str(vm)
                or record.get('original_check', {}).get('unchanged') is not True):
            raise Refused('guest history is not a completed publication')
        value = verify_guest_evidence(archive, record, image, allow_runtime=True)
        final = json.loads(guest_evidence.read(archive / guest_evidence.FINAL))
        candidates.append((archive, record, value, final))
    if len(candidates) > 1: raise Refused('ambiguous guest publication history')
    return candidates[0] if candidates else None


def inspect_guest(vm):
    """Read archived publication evidence; never grant new execution or origin."""
    committed = committed_guest_evidence(vm)
    if committed is None: return None
    _, record, value, final = committed
    result = dict(schemaVersion=1, state='committed-effects', transactionID=record['id'],
        generationID=value['generationID'], planDigest=value['planDigest'], desiredSHA256=value['desiredSHA256'],
        imageSHA256=value['imageSHA256'], outputs=final['outputs'],
        originalEvidence='observed-prior-state', originQualified=False, runtimeValidated=False)
    if record['version'] in (4, 5):
        result.update(currentImageSHA256=value['currentImageSHA256'], runtimeImageChanged=value['runtimeImageChanged'])
        if value['runtimeImageChanged']: result['state'] = 'committed-publication'
    if record.get('operation') is not None:
        from patchers.guest_undo import RECEIPTS
        result['componentReceipts'] = json.loads(guest_evidence.read(committed[0]/RECEIPTS))
    elif record['version'] == 5:
        from patchers.guest_receipts import FILENAME
        result['componentReceipts'] = json.loads(guest_evidence.read(committed[0]/FILENAME))
    return result


def preview_guest_undo(vm, generation, declarations):
    from patchers.guest_undo import preview
    try: return preview(vm, generation, declarations)
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise Refused('guest Undo preview: ' + describe(error)) from error


def prepare_guest_undo(args):
    from patchers.guest_undo import prepare
    prepare(args)
    return 0


def apply_guest_undo(args):
    from patchers.guest_undo import apply
    apply(args)
    return 0


def recover(args):
    """Reopen the recorded original without acquiring new write authority."""
    require_lock(args.vm)
    record = load_record(args.work)
    if not record or record.get('version') not in (2, 3, 4, 5) or record.get('vm') != str(args.vm):
        raise Refused('recovery requires this VM provenance-qualified transaction')
    if record.get('operation') is not None:
        import plistlib
        report = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
        images = report.get('images')
        paths = {str(args.vm/DISK), str(args.work/DISK), str(args.work/PREVIOUS)}
        if (not isinstance(images, list) or any(not isinstance(item, dict) or not isinstance(item.get('image-path'), str) for item in images)
                or any(str(Path(item['image-path']).resolve()) in paths for item in images)):
            raise Refused('Undo recovery requires released image attachments; unmount and detach normally before recovery')
    matches = [path for path in (args.vm / DISK, args.work / DISK, args.work / PREVIOUS)
               if is_same(path, record.get('original'))]
    if len(matches) != 1: raise Refused('recovery has no unique recorded original; retain all files')
    fd = os.open(matches[0], os.O_RDONLY | os.O_NOFOLLOW)
    try:
        args.fd = fd
        if verify_original(fd, record)['unchanged'] is not True:
            raise Refused('recovery original differs; retain all files')
        return finish(args)
    finally: os.close(fd)


def main(argv):
    parser = argparse.ArgumentParser(prog='cfw_disk_txn.py')
    parser.add_argument('command', choices=('stage', 'bind-mount', 'check', 'seal', 'publish', 'finish', 'inspect', 'preview-undo', 'prepare-undo', 'apply-undo', 'recover'))
    parser.add_argument('--fd', type=int)
    parser.add_argument('--owner-pid', type=int)
    parser.add_argument('--phase', choices=('pre-mount', 'pre-install'))
    parser.add_argument('--exit-code', type=int, default=1)
    parser.add_argument('--retain-staged', action='store_true')
    parser.add_argument('--guest-evidence', action='store_true', help='stage a v4 journal requiring provenance and sealed guest effects')
    parser.add_argument('--generation', help='expected committed generation for read-only Undo preview')
    parser.add_argument('--declaration', action='append', default=[], help='declaration to preview undo for; repeatable')
    parser.add_argument('vm', type=Path)
    parser.add_argument('work', type=Path, nargs='?')
    args = parser.parse_args(argv)
    if args.command == 'check' and not args.phase:
        parser.error('check requires --phase')
    if args.guest_evidence and args.command != 'stage': parser.error('--guest-evidence requires stage')
    if args.command not in ('inspect', 'preview-undo', 'recover') and (args.fd is None or args.owner_pid is None or args.work is None):
        parser.error('disk mutation commands require --fd, --owner-pid and work directory')
    if args.command in ('inspect', 'preview-undo') and (args.fd is not None or args.owner_pid is not None or args.work is not None):
        parser.error('read-only commands take only the VM directory')
    if args.command in ('preview-undo', 'prepare-undo'):
        if not args.generation or not args.declaration: parser.error('preview-undo requires --generation and --declaration')
    elif args.generation is not None or args.declaration:
        parser.error('--generation and --declaration require preview-undo or prepare-undo')
    if args.command == 'recover' and (args.work is None or args.fd is not None):
        parser.error('recover requires a work directory and opens the recorded original itself')
    try:
        args.vm = args.vm.resolve(strict=True)
        if args.command == 'preview-undo':
            print(json.dumps(preview_guest_undo(args.vm, args.generation, args.declaration), sort_keys=True))
            return 0
        if args.command == 'inspect':
            value = inspect_guest(args.vm)
            print(json.dumps(value if value is not None else {'schemaVersion': 1, 'state': 'unknown'}, sort_keys=True))
            return 0
        args.work = args.work.resolve(strict=True)
        if args.work.parent != args.vm or not args.work.name.startswith('.cfw_disk.'):
            raise Refused('CFW work directory must be private staging inside this VM')
        if args.command == 'recover':
            args.owner_pid = os.getpid()
            return recover(args)
        return {'stage': stage, 'bind-mount': bind_mount, 'check': check, 'seal': seal, 'publish': publish, 'finish': finish,
                'prepare-undo': prepare_guest_undo, 'apply-undo': apply_guest_undo}[args.command](args)
    except (Refused, OSError, ValueError, KeyError) as error:
        print(f'[-] CFW disk {args.command}: {describe(error)}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Completion markers for the shared IPSW cache (IPSW_DIR, ~/.vphone/ipsws).

One rule covers every entry in the cache. fw_prepare.sh applies it through
this helper; VPhoneIPSWCache (sources/VPhoneCore/VPhoneIPSWCache.swift)
implements the same rule and the same marker format.

- Writes go to `.<name>.partial.<pid>` next to the entry and are published by
  an exclusive rename (renamex_np RENAME_EXCL). A partial whose pid no longer
  exists is removed by the next run.
- An entry is usable only with its completion marker, written last:
      file entry X       `.X.vphone-complete` next to X
      directory entry X  `X/.vphone-extract-complete` inside X
- The marker is JSON naming the content identity (format MARKER_FORMAT):
      file:      {"kind": "file", "source": SOURCE, "size": N, "sha256": HEX,
                  "file": {"inode": I, "mtime_ns": T}}
      directory: {"kind": "directory", "parent": {"size": N, "sha256": HEX}}
  SOURCE is {"url": URL} for an http(s) source, or for a local file
  {"path": REALPATH, "device": D, "inode": I, "size": N, "mtime_ns": T}.
  A directory entry is an extraction of the file entry whose size and SHA-256
  it records.
- An entry without a marker, with a marker of another format or source, or
  whose file no longer has the recorded size, inode and mtime is not usable.
  It is removed (`discard`) and fetched again; nothing is reused by name.
- Publishing, discarding and the marker write hold flock(2) on the cache
  directory itself, the lock VPhoneLibraryLock takes, so a reader never sees a
  published entry before its marker.

Usage:
  ipsw_cache_entry.py check FILE --source SRC
  ipsw_cache_entry.py identify SRC
  ipsw_cache_entry.py discard FILE --source SRC
  ipsw_cache_entry.py publish FILE PARTIAL --source SRC [--expect-source JSON]
                      [--require-member NAME]
  ipsw_cache_entry.py check-dir DIR --parent FILE
  ipsw_cache_entry.py discard-dir DIR --parent FILE
  ipsw_cache_entry.py publish-dir DIR PARTIAL --parent FILE
check and check-dir exit 0 when the entry is usable and 1 when it is not.
"""
import argparse
import ctypes
import ctypes.util
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import time
import zipfile

MARKER_FORMAT = 'vphone-ipsw-cache/1'
FILE_MARKER_SUFFIX = '.vphone-complete'
DIRECTORY_MARKER = '.vphone-extract-complete'
LOCK_TIMEOUT = 600.0
CHUNK = 8 << 20
RENAME_EXCL = 0x00000004

_libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
_libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]


class EntryError(Exception):
    pass


# MARK: - Identity

def is_remote(source):
    return source.startswith(('http://', 'https://'))


def source_identity(source):
    if is_remote(source):
        return {'url': source}
    path = os.path.realpath(source)
    info = os.stat(path)
    if not stat.S_ISREG(info.st_mode):
        raise EntryError(f'{source} is not a regular file')
    return {'path': path, 'device': info.st_dev, 'inode': info.st_ino,
            'size': info.st_size, 'mtime_ns': info.st_mtime_ns}


def file_marker_path(entry):
    entry = Path(entry)
    return entry.parent / f'.{entry.name}{FILE_MARKER_SUFFIX}'


def read_json(path):
    try:
        with open(path, 'rb') as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def file_marker(entry):
    marker = read_json(file_marker_path(entry))
    if not marker or marker.get('format') != MARKER_FORMAT or marker.get('kind') != 'file':
        return None
    return marker


def file_problem(entry, source):
    """Why FILE is not a usable entry for SOURCE, or None when it is."""
    entry = Path(entry)
    try:
        info = os.lstat(entry)
    except FileNotFoundError:
        return 'absent'
    if not stat.S_ISREG(info.st_mode):
        return 'not a regular file'
    marker = file_marker(entry)
    if marker is None:
        return 'no completion marker'
    try:
        current = source_identity(source)
    except (OSError, EntryError) as error:
        return f'source unavailable: {error}'
    if marker.get('source') != current:
        return 'completion marker names another source'
    recorded = marker.get('file') or {}
    if (marker.get('size') != info.st_size or recorded.get('inode') != info.st_ino
            or recorded.get('mtime_ns') != info.st_mtime_ns):
        return 'file changed after its completion marker was written'
    if not isinstance(marker.get('sha256'), str) or len(marker['sha256']) != 64:
        return 'completion marker has no content digest'
    return None


def parent_identity(parent):
    marker = file_marker(parent)
    if marker is None:
        raise EntryError(f'{parent} has no completion marker')
    try:
        info = os.lstat(parent)
    except FileNotFoundError:
        raise EntryError(f'{parent} is absent') from None
    recorded = marker.get('file') or {}
    if (marker.get('size') != info.st_size or recorded.get('inode') != info.st_ino
            or recorded.get('mtime_ns') != info.st_mtime_ns):
        raise EntryError(f'{parent} changed after its completion marker was written')
    return {'size': marker['size'], 'sha256': marker['sha256']}


def directory_problem(entry, parent):
    entry = Path(entry)
    try:
        info = os.lstat(entry)
    except FileNotFoundError:
        return 'absent'
    if not stat.S_ISDIR(info.st_mode):
        return 'not a directory'
    marker = read_json(entry / DIRECTORY_MARKER)
    if not marker or marker.get('format') != MARKER_FORMAT or marker.get('kind') != 'directory':
        return 'no completion marker'
    try:
        expected = parent_identity(parent)
    except EntryError as error:
        return str(error)
    if marker.get('parent') != expected:
        return 'extracted from another IPSW'
    return None


# MARK: - Locking and publishing

class DirectoryLock:
    """flock(2) on the directory itself, the lock VPhoneLibraryLock takes."""

    def __init__(self, directory, timeout=LOCK_TIMEOUT):
        self.path = os.path.realpath(directory)
        self.timeout = timeout
        self.fd = None

    def __enter__(self):
        fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as error:
                if error.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EINTR):
                    os.close(fd)
                    raise
                if time.monotonic() > deadline:
                    os.close(fd)
                    raise EntryError(f'cache directory {self.path} is locked by another run') from None
                time.sleep(0.1)
        self.fd = fd
        return self

    def __exit__(self, *_):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def move_exclusive(source, destination):
    if _libc.renamex_np(os.fsencode(source), os.fsencode(destination), RENAME_EXCL) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def write_json_atomically(path, value):
    path = Path(path)
    temporary = path.parent / f'{path.name}.partial.{os.getpid()}'
    with open(temporary, 'w') as handle:
        json.dump(value, handle, sort_keys=True)
        handle.write('\n')
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o644)
    os.replace(temporary, path)


def remove_path(path):
    path = Path(path)
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return False
    if stat.S_ISDIR(info.st_mode):
        shutil.rmtree(path)
    else:
        os.unlink(path)
    return True


def remove_file_entry(entry):
    removed = remove_path(entry)
    return remove_path(file_marker_path(entry)) or removed


def sha256_of(path):
    digest = hashlib.sha256()
    size = 0
    with open(path, 'rb') as handle:
        while True:
            chunk = handle.read(CHUNK)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def require_member(path, name):
    try:
        with zipfile.ZipFile(path) as archive:
            info = archive.getinfo(name)
            if info.file_size <= 0:
                raise EntryError(f'{path} has an empty {name}')
    except (zipfile.BadZipFile, KeyError, OSError) as error:
        raise EntryError(f'{path} is not a complete IPSW ({name}: {error})') from None


# MARK: - Commands

def discard(entry, source):
    entry = Path(entry)
    with DirectoryLock(entry.parent):
        problem = file_problem(entry, source)
        if problem in (None, 'absent'):
            if problem == 'absent' and file_marker_path(entry).exists():
                remove_path(file_marker_path(entry))
            return
        print(f'==> Discarding cached {entry.name} ({problem})')
        remove_file_entry(entry)


def publish(entry, partial, source, expect_source=None, member=None):
    """Publish PARTIAL as FILE for SOURCE; prints the outcome."""
    entry, partial = Path(entry), Path(partial)
    info = os.lstat(partial)
    if not stat.S_ISREG(info.st_mode):
        raise EntryError(f'{partial} is not a regular file')
    identity = source_identity(source)
    if expect_source is not None and identity != expect_source:
        raise EntryError(f'{source} changed while it was copied')
    if member:
        require_member(partial, member)
    digest, size = sha256_of(partial)
    if size != os.lstat(partial).st_size:
        raise EntryError(f'{partial} changed while it was hashed')
    with DirectoryLock(entry.parent):
        if file_problem(entry, source) is None:
            # Another run published the same source meanwhile.
            os.unlink(partial)
            print(f'==> Using {entry.name} published by another run')
            return
        remove_file_entry(entry)
        move_exclusive(partial, entry)
        published = os.lstat(entry)
        write_json_atomically(file_marker_path(entry), {
            'format': MARKER_FORMAT, 'kind': 'file', 'source': identity,
            'size': size, 'sha256': digest,
            'file': {'inode': published.st_ino, 'mtime_ns': published.st_mtime_ns},
        })
    print(f'==> Cached {entry.name} (sha256 {digest}, {size} bytes)')


def set_aside(entry):
    """Rename ENTRY to a partial name (fast, under the lock); the caller
    removes it after releasing the lock. A crash leaves an ordinary partial
    that the next run removes."""
    entry = Path(entry)
    if not os.path.lexists(entry):
        return None
    aside = entry.parent / f'.{entry.name}.partial.discard.{os.getpid()}'
    remove_path(aside)
    os.rename(entry, aside)
    return aside


def discard_directory(entry, parent):
    entry = Path(entry)
    with DirectoryLock(entry.parent):
        problem = directory_problem(entry, parent)
        if problem in (None, 'absent'):
            return
        print(f'==> Discarding incomplete extraction {entry.name} ({problem})')
        aside = set_aside(entry)
    if aside:
        remove_path(aside)


def publish_directory(entry, partial, parent):
    entry, partial = Path(entry), Path(partial)
    if not stat.S_ISDIR(os.lstat(partial).st_mode):
        raise EntryError(f'{partial} is not a directory')
    write_json_atomically(partial / DIRECTORY_MARKER, {
        'format': MARKER_FORMAT, 'kind': 'directory', 'parent': parent_identity(parent),
    })
    aside = None
    with DirectoryLock(entry.parent):
        if directory_problem(entry, parent) is None:
            print(f'==> Using {entry.name} extracted by another run')
            aside = partial
        else:
            aside = set_aside(entry)
            move_exclusive(partial, entry)
    if aside:
        remove_path(aside)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('check')
    command.add_argument('entry')
    command.add_argument('--source', required=True)
    command = commands.add_parser('identify')
    command.add_argument('source')
    command = commands.add_parser('discard')
    command.add_argument('entry')
    command.add_argument('--source', required=True)
    command = commands.add_parser('publish')
    command.add_argument('entry')
    command.add_argument('partial')
    command.add_argument('--source', required=True)
    command.add_argument('--expect-source')
    command.add_argument('--require-member')
    for name in ('check-dir', 'discard-dir'):
        command = commands.add_parser(name)
        command.add_argument('entry')
        command.add_argument('--parent', required=True)
    command = commands.add_parser('publish-dir')
    command.add_argument('entry')
    command.add_argument('partial')
    command.add_argument('--parent', required=True)
    args = parser.parse_args(argv)

    try:
        if args.command == 'check':
            problem = file_problem(args.entry, args.source)
            if problem:
                print(f'{args.entry}: {problem}', file=sys.stderr)
                return 1
        elif args.command == 'identify':
            print(json.dumps(source_identity(args.source), sort_keys=True))
        elif args.command == 'discard':
            discard(args.entry, args.source)
        elif args.command == 'publish':
            expected = json.loads(args.expect_source) if args.expect_source else None
            publish(args.entry, args.partial, args.source, expected, args.require_member)
        elif args.command == 'check-dir':
            problem = directory_problem(args.entry, args.parent)
            if problem:
                print(f'{args.entry}: {problem}', file=sys.stderr)
                return 1
        elif args.command == 'discard-dir':
            discard_directory(args.entry, args.parent)
        elif args.command == 'publish-dir':
            publish_directory(args.entry, args.partial, args.parent)
    except (EntryError, OSError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())

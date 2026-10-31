#!/usr/bin/env python3
"""Directory-inode flock shared with VPhoneVMLock; no removable lock file."""
import datetime
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid

FD_ENV = 'VPHONE_VM_LOCK_FD'


def check_inherited(directory):
    fd = int(os.environ.get(FD_ENV, '-1'))
    actual = os.fstat(fd)
    expected = os.stat(directory)
    if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
        raise ValueError('inherited descriptor belongs to another VM')
    # Re-locking the same open-file description is harmless; an independently
    # opened descriptor cannot use this check to bypass an existing owner.
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if os.path.lexists(directory / '.firmware-transaction'):
        raise ValueError('pending firmware transaction; run patch-firmware --recover')
    return fd


def main(argv):
    if argv[:1] == ['--check-inherited']:
        try:
            check_inherited(Path(argv[1]).resolve(strict=True))
            return 0
        except (OSError, ValueError, IndexError):
            return 1
    if len(argv) < 4 or argv[2] != '--':
        print('usage: vm_lock.py VM_DIR OPERATION -- COMMAND [ARGS...]', file=sys.stderr)
        return 2
    fd = -1
    try:
        directory = Path(argv[0]).resolve(strict=True)
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if argv[1] != 'fw-patch' and os.path.lexists(directory / '.firmware-transaction'):
            raise ValueError('pending firmware transaction; run patch-firmware --recover')
        info = os.fstat(fd)
        record = dict(bundleIdentifier=f'{info.st_dev}:{info.st_ino}', bundlePath=str(directory),
                      pid=os.getpid(), instanceID=str(uuid.uuid4()),
                      startedAt=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), operation=argv[1])
        # The record is diagnostic; stale records never block acquisition.
        name = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', dir=directory, prefix='.runtime-', delete=False) as output:
                name = output.name
                os.fchmod(output.fileno(), 0o644)
                json.dump(record, output, indent=2)
                output.write('\n')
            os.replace(name, directory / '.vphone-runtime.json')
        except OSError as error:
            print(f"Warning: runtime record could not be written: {error}", file=sys.stderr)
        finally:
            if name and os.path.exists(name):
                try:
                    os.unlink(name)
                except OSError as error:
                    print(f"Warning: runtime record temporary file retained: {error}", file=sys.stderr)
        # Explicit operation-tree inheritance: exec preserves the recorded PID.
        # Descendants still writing after shell death keep the lock until exit.
        os.set_inheritable(fd, True)
        env = dict(os.environ, **{FD_ENV: str(fd)})
        os.execvpe(argv[3], argv[3:], env)
    except (OSError, ValueError) as error:
        print(f'VM lock unavailable: {error}', file=sys.stderr)
        return 1
    finally:
        if fd >= 0:
            os.close(fd)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

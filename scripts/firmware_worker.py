#!/usr/bin/env python3
"""Keep transaction tools mutually exclusive with firmware recovery.

The worker outlives a killed Swift parent and holds the lock until the tool
exits. Validate the lock pathname after acquiring it: recovery may have moved
the transaction while this worker was waiting to start.
"""

import fcntl
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys


def main():
    transaction = Path(sys.argv[1])
    command = sys.argv[2:]
    inherited = bool(len(command) >= 2 and command[:2] == ["--lock-fd", "3"])
    if inherited:
        command = command[2:]
    if not command or not Path(command[0]).is_absolute():
        raise ValueError("an absolute tool path is required")
    # Descriptor 3 carries the parent's existing open file description during commit.
    # dup retains the flock if the parent dies; closing it never unlocks the
    # still-running parent. The pathname identity below remains mandatory.
    fd = os.dup(3) if inherited else os.open(transaction, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        current = os.stat(transaction, follow_symlinks=False)
        opened = os.fstat(fd)
        if not stat.S_ISDIR(current.st_mode) or not stat.S_ISDIR(opened.st_mode):
            raise RuntimeError("firmware lock must be a real directory")
        if inherited and any(parent.is_symlink() for parent in (transaction, *transaction.parents)):
            raise RuntimeError("firmware transaction has a linked ancestor")
        if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
            raise RuntimeError("firmware inherited lock differs from transaction")
        if inherited:
            # A newly opened, unlocked descriptor is not an inherited lease.
            probe = os.open(transaction, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise RuntimeError("inherited firmware lock was not already held")
            finally:
                os.close(probe)
        fcntl.flock(fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if inherited else 0))
        current = os.stat(transaction, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
            raise RuntimeError("firmware transaction moved before tool startup")
        child = None
        pending_signals = []

        def forward(signum, _frame):
            if child is None:
                pending_signals.append(signum)
            else:
                try:
                    os.killpg(child.pid, signum)
                except ProcessLookupError:
                    pass

        # Signal forwarding must not release the recovery lock before wait().
        signal.signal(signal.SIGINT, forward)
        signal.signal(signal.SIGTERM, forward)
        child = subprocess.Popen(command, cwd=transaction / "work", stdin=subprocess.DEVNULL,
                                 start_new_session=True, pass_fds=(fd,),
                                 env=dict(os.environ, VPHONE_FIRMWARE_WORKER_FD=str(fd)))
        for signum in pending_signals:
            forward(signum, None)
        code = child.wait()
        return code if code >= 0 else 128 - code
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f"firmware worker: {error}", file=sys.stderr)
        sys.exit(1)

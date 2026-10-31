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
import subprocess
import sys


def main():
    transaction = Path(sys.argv[1])
    command = sys.argv[2:]
    if not command or not Path(command[0]).is_absolute():
        raise ValueError("an absolute tool path is required")
    fd = os.open(transaction, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        current = os.stat(transaction, follow_symlinks=False)
        opened = os.fstat(fd)
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
                                 start_new_session=True)
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

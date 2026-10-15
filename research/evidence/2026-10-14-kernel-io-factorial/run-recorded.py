"""Exclusive logs for isolated tests. No VM operation or acceptance disk access."""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import time

E = Path(__file__).resolve().parent
VM = Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')


def terminate_owned(process):
    """Only a child created with start_new_session=True; never a saved PID."""
    sent = []
    try:
        if process.poll() is None:
            try: os.killpg(process.pid, signal.SIGTERM); sent.append('SIGTERM')
            except ProcessLookupError: pass
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid, signal.SIGKILL); sent.append('SIGKILL')
                except ProcessLookupError: pass
                process.wait(timeout=5)
        return dict(signals=sent, complete=process.poll() is not None, error=None)
    except BaseException as error:
        return dict(signals=sent, complete=False, error=type(error).__name__)


def terminated(_number, _frame):
    raise InterruptedError('Recorded runner received SIGTERM')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--set', action='append', default=[])
    parser.add_argument('--guard-task8', action='store_true')
    parser.add_argument('--artifact-root', type=Path)
    parser.add_argument('--timeout', type=float, default=600)
    parser.add_argument('label')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    assert re.fullmatch('[a-z0-9]+(?:-[a-z0-9]+)*', args.label)
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    assert command
    assert math.isfinite(args.timeout) and 0 < args.timeout <= 3600
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('VPHONE_TEST_', 'VPHONE_LESS_', 'VPHONE_C4_', 'VPHONE_KERNEL_'))}
    overrides = {}
    for value in args.set:
        key, value = value.split('=', 1)
        assert key.startswith('VPHONE_KERNEL_IO_')
        overrides[key] = value
    env.update(overrides)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    return run(args, command, env, overrides)


def run(args, command, env, overrides):
    locks = {}
    try:
        return run_locked(args, command, env, overrides, lambda kind, fd: locks.__setitem__(kind, fd))
    finally:
        for fd in locks.values(): os.close(fd)


def run_locked(args, command, env, overrides, track_lock):
    lock, artifact_lock = None, None
    if args.artifact_root:
        root = args.artifact_root.resolve()
        assert root.parent == Path('/private/tmp') and root.name.startswith('vphone-kernel-io-')
        artifact_lock = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        track_lock('artifact', artifact_lock)
        fcntl.flock(artifact_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if args.guard_task8:
        lock = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        track_lock('acceptance', lock)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name in ('.firmware-transaction', '.firmware-desired-pending.json'):
            try: os.lstat(VM / name)
            except FileNotFoundError: continue
            raise RuntimeError('Task8 pending operation')
        processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True, timeout=10)
        for line in processes.splitlines():
            if (str(VM) in line or '/tmp/vphone-task8-acceptance-vms/task8-copy' in line) and 'vphone-vm' in line:
                raise RuntimeError('Task8 VM is running')
        images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist'], timeout=10))
        assert not any(os.path.realpath(image.get('image-path', '')).startswith(str(VM.parent) + '/')
                       for image in images.get('images', [])), 'Task8 image attached'
    log = E / (args.label + '.log'); result_path = E / (args.label + '.json')
    assert not result_path.exists()
    started = time.monotonic()
    process, timed_out, interrupted = None, False, None
    cleanup = dict(signals=[], complete=True, error=None)
    previous_handler = signal.signal(signal.SIGTERM, terminated)
    with log.open('x') as output:
        try:
            process = subprocess.Popen(command, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True; cleanup = terminate_owned(process)
        except BaseException as error:
            interrupted = type(error).__name__
            if process is not None: cleanup = terminate_owned(process)
        finally:
            signal.signal(signal.SIGTERM, previous_handler)
    code = None if process is None else process.returncode
    record = dict(command=command, environment_overrides=overrides, exit_code=code,
                  elapsed_seconds=time.monotonic() - started, log=str(log),
                  acceptance_directory_lock_held=args.guard_task8,
                  artifact_directory_lock_held=str(args.artifact_root) if artifact_lock is not None else None,
                  child_pid=None if process is None else process.pid, child_start_new_session=True,
                  timeout_seconds=args.timeout, timed_out=timed_out, interrupted=interrupted,
                  cleanup_signals_to_owned_child_group=cleanup['signals'],
                  cleanup_complete=cleanup['complete'], cleanup_error=cleanup['error'])
    with result_path.open('x') as output:
        json.dump(record, output, indent=2); output.write('\n')
    print(json.dumps(record), flush=True)
    return 124 if timed_out else (1 if not cleanup['complete'] or interrupted or code is None or code < 0 else code)


if __name__ == '__main__': raise SystemExit(main())

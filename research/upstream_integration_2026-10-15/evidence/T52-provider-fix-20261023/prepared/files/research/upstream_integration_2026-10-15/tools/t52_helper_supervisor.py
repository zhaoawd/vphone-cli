"""Bound a named helper in a separate process, outside its LLDB/Python GIL."""
import signal
import subprocess
import time


def supervise(child, deadline, stop_marker, *, grace_seconds=2):
    steps = []
    # Reserve enough time for escalation before the absolute authorization end.
    reserve = grace_seconds * 3 + 1
    while child.poll() is None and not stop_marker.exists() and time.time() < deadline - reserve:
        time.sleep(.1)
    for name, sig in [('SIGINT', signal.SIGINT), ('SIGTERM', signal.SIGTERM), ('SIGKILL', signal.SIGKILL)]:
        if child.poll() is not None:
            break
        child.send_signal(sig)
        steps.append(name)
        try:
            child.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            continue
    if child.poll() is None:
        raise RuntimeError('Named helper remained alive after SIGKILL')
    return dict(state='stopped', workerPID=child.pid, exitCode=child.returncode,
                signals=steps, stoppedAt=time.time(), deadline=deadline,
                withinDeadline=time.time() <= deadline)

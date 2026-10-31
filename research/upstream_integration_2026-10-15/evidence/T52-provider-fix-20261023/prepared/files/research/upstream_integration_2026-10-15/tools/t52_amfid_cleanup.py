"""Resume only the same amfid if a completed, detached window left it paused."""
import os
import signal
import subprocess
import time


def process_identity(pid):
    row = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'pid=,uid=,lstart=,comm='], capture_output=True, text=True)
    if row.returncode != 0 or not row.stdout.strip(): return None
    fields = row.stdout.strip().split(None, 7)
    if len(fields) != 8: raise ValueError('Unexpected process identity shape')
    return dict(pid=int(fields[0]), uid=int(fields[1]), started=' '.join(fields[2:7]), executable=fields[7])


def resume_action(before, current, status, *, helper_stopped, debugserver_absent):
    if not helper_stopped or not debugserver_absent:
        return 'refused_debugger_or_helper_remains'
    if current is None: return 'original_process_exited'
    if (before != current or before.get('uid') != 0 or before.get('executable') != '/usr/libexec/amfid'):
        return 'refused_identity_changed'
    return 'SIGCONT' if 'T' in status else 'not_paused'


def cleanup(before):
    # The caller has already waited for its exact helper child to exit.
    debugserver = subprocess.run(['/usr/bin/pgrep', '-x', 'debugserver'], capture_output=True, text=True)
    current = process_identity(before['pid'])
    status = subprocess.run(['/bin/ps', '-p', str(before['pid']), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
    action = resume_action(before, current, status, helper_stopped=True, debugserver_absent=debugserver.returncode == 1)
    result = dict(action=action, before=before, observed=current, statusBefore=status, reattached=False)
    if action == 'SIGCONT':
        os.kill(before['pid'], signal.SIGCONT)
        until = time.monotonic() + 2
        while True:
            current = process_identity(before['pid'])
            after_status = subprocess.run(['/bin/ps', '-p', str(before['pid']), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
            result.update(observedAfter=current, statusAfter=after_status)
            if current is None or 'T' not in after_status or time.monotonic() >= until: break
            time.sleep(.05)
        result['passed'] = current is None or (current == before and 'T' not in after_status)
    else:
        result['passed'] = action in ('not_paused', 'original_process_exited')
    return result

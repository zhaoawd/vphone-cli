#!/usr/bin/python3
"""One authorization window, one VM CDHash, bounded reattachment; no persistent policy."""
import gc
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
sys.dont_write_bytecode = True
WORK = Path('/Users/kolar/github/vphone-cli/.build/t52-camera-diagnostics-20261022/boot-window')
CDHASH = '89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541'
MAX_SECONDS = 900
MAX_ATTACHMENTS = 1
VM = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.56be1ce20ded/VPhone.bundle/Contents/MacOS/vphone-vm')
VM_SHA256 = '266810c8ae29af8fbc8e54a2c0a684b439dfea55f96b503aa8e6d4fa2ab3b439'
AUTH = WORK / 'authorization-window.json'
STATE = WORK / 'helper-state.json'
STOP = WORK / 'stop-authorized-helper'
if os.geteuid() != 0:
    raise SystemExit('Administrator authentication is required')
if hashlib.sha256(VM.read_bytes()).hexdigest() != VM_SHA256:
    raise SystemExit('Approved VM bytes changed')
if sys.argv[1:] == ['--worker']:
    authorization = json.loads(AUTH.read_text())
    deadline = authorization['deadline']
    if authorization['cdhash'] != CDHASH or STOP.exists() or time.time() >= deadline:
        raise SystemExit('Authorization expired or stopped')
    sys.path.insert(0, '/Users/kolar/Library/Python/3.9/lib/python/site-packages')
    from amfidont import bypass_runtime as runtime
    runtime.load_persistent_config = lambda: {'paths': [], 'cdhashes': []}
    runtime.config_modified_time_state = lambda: (None, None)
    stopped = threading.Event()
    record = dict(pid=os.getpid(), cdhash=CDHASH, startedAt=authorization['startedAt'],
                  deadline=deadline, maxSeconds=MAX_SECONDS, maxAttachments=MAX_ATTACHMENTS,
                  attempt=0, state='starting')
    def save():
        temporary = STATE.with_suffix('.new')
        temporary.write_text(json.dumps(record, indent=2) + '\n')
        os.replace(temporary, STATE)
    def watch_stop():
        while time.time() < deadline and not STOP.exists() and not stopped.is_set():
            time.sleep(.2)
        if not stopped.is_set():
            stopped.set()
            os.kill(os.getpid(), signal.SIGINT)
    original_loop = runtime.bypass_loop
    def observed_loop(process, target, *args, **kwargs):
        record.update(state='running', targetPID=process.GetProcessID(), observedAt=time.time())
        save()
        try:
            return original_loop(process, target, *args, **kwargs)
        except Exception as error:
            record.update(state='attachment-ended', error=str(error), observedAt=time.time())
            save()
            print('Attachment ended:', repr(error), flush=True)
    runtime.bypass_loop = observed_loop
    save()
    threading.Thread(target=watch_stop, daemon=True).start()
    try:
        for attempt in range(1, MAX_ATTACHMENTS + 1):
            if stopped.is_set() or STOP.exists() or time.time() >= deadline:
                break
            record.update(attempt=attempt, state='attaching', observedAt=time.time())
            save()
            runtime.run_bypass(paths=[], cdhashes=[CDHASH], verbose=True,
                               allow_all=False, spoof_apple=True)
            gc.collect()
            if stopped.is_set() or STOP.exists() or time.time() >= deadline:
                break
            if attempt < MAX_ATTACHMENTS:
                print('Reattachment remains inside the original absolute deadline', deadline, flush=True)
                time.sleep(.5)
    finally:
        stopped.set()
        record.update(state='stopped', stoppedAt=time.time())
        save()
elif sys.argv[1:] == ['--supervisor']:
    authorization = json.loads(AUTH.read_text())
    if authorization['cdhash'] != CDHASH or authorization['deadline'] - authorization['startedAt'] != MAX_SECONDS:
        raise SystemExit('Authorization does not match this window')
    sys.path.insert(0, '/Users/kolar/github/vphone-cli/research/upstream_integration_2026-10-15/tools')
    from t52_helper_supervisor import supervise
    child = subprocess.Popen([sys.executable, '-u', str(Path(__file__).resolve()), '--worker'])
    result = supervise(child, authorization['deadline'], STOP)
    result.update(supervisorPID=os.getpid(), cdhash=CDHASH, attachments=1)
    (WORK / 'supervisor-stop.json').write_text(json.dumps(result, indent=2) + '\n')
elif not sys.argv[1:]:
    if STOP.exists():
        raise SystemExit('Stop marker exists')
    # Wake the demand-launched daemon using only the pinned binary's help path.
    probe = subprocess.run([str(VM), '--help'], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=15)
    daemon = subprocess.run(['/usr/bin/pgrep', '-x', 'amfid'], capture_output=True, text=True)
    if daemon.returncode != 0 or len(daemon.stdout.split()) != 1:
        raise SystemExit('One live amfid process is required; no authorization window started')
    (WORK / 'pre-attachment-probe.json').write_text(json.dumps(dict(
        helpExit=probe.returncode, amfidPID=int(daemon.stdout.strip()), vmDiskOpened=False), indent=2)+'\n')
    started = time.time()
    fd = os.open(AUTH, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, 'w') as stream:
        json.dump(dict(cdhash=CDHASH, startedAt=started, deadline=started+MAX_SECONDS), stream)
    with (WORK / 'scoped-amfidont.log').open('ab') as log:
        child = subprocess.Popen([sys.executable, '-u', str(Path(__file__).resolve()), '--supervisor'],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    print('Supervisor PID:', child.pid, 'CDHash:', CDHASH, 'absolute deadline:', started+MAX_SECONDS)
else:
    raise SystemExit('Unsupported arguments')

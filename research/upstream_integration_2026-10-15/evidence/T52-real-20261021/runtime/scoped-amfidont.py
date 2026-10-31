#!/usr/bin/env python3
"""Run the installed amfidont for the one explicitly authorized VM CDHash."""
import os
import signal
import threading
import time
import json
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True

ROOT = Path('/Users/kolar/github/vphone-cli')
CDHASH = '2d9b99f3a41e6f7ba7bb3d5558f15524b409b3b5'

if os.geteuid() != 0:
    raise SystemExit('Native administrator authentication is required')
if sys.argv[1:] == ['--worker']:
    sys.path.insert(0, '/Users/kolar/Library/Python/3.9/lib/python/site-packages')
    from amfidont import bypass_runtime
    work = ROOT / '.build/t52-real-20261021'
    state = work / 'helper-state.json'
    release = work / 'stop-authorized-helper'
    if release.exists():
        raise SystemExit('Stop marker already exists; no helper started')
    started = time.time()
    record = dict(pid=os.getpid(), cdhash=CDHASH, startedAt=started, maxSeconds=1800, state='starting')
    state.write_text(json.dumps(record, indent=2) + '\n')
    def watch_stop():
        while time.time() - started < 1800 and not release.exists():
            time.sleep(.2)
        os.kill(os.getpid(), signal.SIGINT)
    watcher = threading.Thread(target=watch_stop, daemon=True)
    watcher.start()
    # Keep this process restricted to the approved hash. Existing persistent
    # path/hash allowlists are neither loaded nor modified.
    bypass_runtime.load_persistent_config = lambda: {'paths': [], 'cdhashes': []}
    bypass_runtime.config_modified_time_state = lambda: (None, None)
    try:
        record['state'] = 'running'
        state.write_text(json.dumps(record, indent=2) + '\n')
        bypass_runtime.run_bypass(paths=[], cdhashes=[CDHASH], verbose=True,
                                  allow_all=False, spoof_apple=True)
    finally:
        record.update(state='stopped', stoppedAt=time.time())
        state.write_text(json.dumps(record, indent=2) + '\n')
elif not sys.argv[1:]:
    log = ROOT / '.build/t52-real-20261021/scoped-amfidont-t52.log'
    with log.open('ab') as stream:
        process = subprocess.Popen([sys.executable, '-u', str(Path(__file__).resolve()), '--worker'],
            stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
            start_new_session=True)
    print(f'Authorized CDHash: {CDHASH}; helper PID: {process.pid}', flush=True)
else:
    raise SystemExit('Unsupported helper arguments')

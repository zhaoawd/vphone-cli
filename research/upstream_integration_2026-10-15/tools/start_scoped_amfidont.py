#!/usr/bin/env python3
"""Run the installed amfidont for the one explicitly authorized VM CDHash."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
CDHASH = '89b70a253cad2adea133b3e875519afaf72c5d17'

if os.geteuid() != 0:
    raise SystemExit('Native administrator authentication is required')
if sys.argv[1:] == ['--worker']:
    sys.path.insert(0, '/Users/kolar/Library/Python/3.9/lib/python/site-packages')
    from amfidont import bypass_runtime
    # Keep this process restricted to the approved hash. Existing persistent
    # path/hash allowlists are neither loaded nor modified.
    bypass_runtime.load_persistent_config = lambda: {'paths': [], 'cdhashes': []}
    bypass_runtime.config_modified_time_state = lambda: (None, None)
    bypass_runtime.run_bypass(paths=[], cdhashes=[CDHASH], verbose=True,
                              allow_all=False, spoof_apple=True)
elif not sys.argv[1:]:
    log = ROOT / '.build/t32-metadata-debug/scoped-amfidont-89b70a25.log'
    with log.open('ab') as stream:
        process = subprocess.Popen([sys.executable, '-u', str(Path(__file__).resolve()), '--worker'],
            stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
            start_new_session=True)
    print(f'Authorized CDHash: {CDHASH}; helper PID: {process.pid}', flush=True)
else:
    raise SystemExit('Unsupported helper arguments')

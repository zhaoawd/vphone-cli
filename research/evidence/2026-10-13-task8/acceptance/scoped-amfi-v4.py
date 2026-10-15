#!/usr/bin/env python3
"""Temporary Task 8 v4 single-CDHash driver; never loads persistent rules."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

BINARY = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-vm')
SHA256 = '0e5944b2b79aaa059af156cb47824c399183d970a93db35b839b5dda39b31ca1'
CDHASH = '43c00d51b4c7f07a5feba006f3c244edbac39cea'
MODULES = Path('/Users/qcz3840/Library/Python/3.9/lib/python/site-packages')
RUNTIME_SHA256 = 'bd418fcb2732c08162a115b8537fa4cde8cbb4212bc2361e9113decf8325bab0'
assert sys.argv[1:] in [['--check'], ['--run']], 'only --check or --run allowed'
assert not BINARY.is_symlink() and hashlib.sha256(BINARY.read_bytes()).hexdigest() == SHA256
signature = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(BINARY)],
                           capture_output=True, text=True, check=True).stderr
assert 'CDHash=' + CDHASH + '\n' in signature, 'authorized VM signature changed'
assert hashlib.sha256((MODULES / 'amfidont/bypass_runtime.py').read_bytes()).hexdigest() == RUNTIME_SHA256
print(json.dumps(dict(binary=str(BINARY), sha256=SHA256, cdhashes=[CDHASH], paths=[],
    allow_all=False, spoof_apple=True, persistent_config=False, driver_pid=os.getpid(),
    permitted_vm='/private/tmp/vphone-task8-acceptance-vms/task8-copy',
    source_reference='research/upstream_integration_2026-10-06/evidence/B35/T08/scoped_amfi.py',
    cleanup='SIGINT driver; stop inferior, delete breakpoints, detach amfid, destroy debugger')), flush=True)
if sys.argv[1:] == ['--check']:
    raise SystemExit(0)
assert os.geteuid() == 0, 'administrator execution required'
sys.dont_write_bytecode = True
sys.path.insert(0, str(MODULES))
from amfidont import bypass_runtime as runtime

# No persistent rules are read initially or reloaded during this process.
runtime.load_persistent_config = lambda: {'paths': [], 'cdhashes': []}
runtime.config_modified_time_state = lambda: (None, None)

def stop_requested(_signal, _frame):
    raise KeyboardInterrupt()

signal.signal(signal.SIGTERM, stop_requested)
lldb = runtime.lldb
debugger = lldb.SBDebugger.Create()
debugger.SetAsync(False)
target = debugger.CreateTarget('')
process = None
attached = False

def check_help():
    started = time.monotonic()
    command = [str(BINARY), '--help']
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=30)
    evidence = Path(__file__).resolve().parent
    (evidence / 'scoped-amfi-v4-vm-help.log').write_text(result.stdout)
    record = dict(command=command, exit_code=result.returncode,
                  elapsed_seconds=time.monotonic() - started)
    (evidence / 'scoped-amfi-v4-vm-help.json').write_text(json.dumps(record, indent=2) + '\n')
    print('TASK8_V4_SCOPED_AMFI_HELP ' + json.dumps(record), flush=True)

try:
    error = lldb.SBError()
    process = target.AttachToProcessWithName(debugger.GetListener(), runtime.AMFID_PATH, False, error)
    if error.Fail() or not process.IsValid():
        raise RuntimeError('attach failed: ' + str(error))
    attached = True
    for name in ('-[AMFIPathValidator_macos validateWithError:]', '-[AMFIPathValidator_macos isApple]'):
        breakpoint = target.BreakpointCreateByName(name)
        if breakpoint.GetNumLocations() == 0:
            raise RuntimeError('breakpoint not resolved: ' + name)
    print('TASK8_V4_SCOPED_AMFI_READY amfid_pid=' + str(process.GetProcessID()), flush=True)
    threading.Thread(target=check_help, daemon=True).start()
    runtime.bypass_loop(process, target, paths=[], cdhashes=[CDHASH], verbose=True,
                        allow_all=False, spoof_apple=True)
except KeyboardInterrupt:
    print('TASK8_V4_SCOPED_AMFI_STOP_REQUESTED', flush=True)
finally:
    if process is not None and process.IsValid():
        print('TASK8_V4_SCOPED_AMFI_EXIT_STATE ' + json.dumps(dict(state=process.GetState(),
            status=process.GetExitStatus(), description=process.GetExitDescription())), flush=True)
    if attached and process is not None and process.IsValid():
        process.Stop()
        target.DeleteAllBreakpoints()
        error = process.Detach()
        print('TASK8_V4_SCOPED_AMFI_DETACH ' + str(error), flush=True)
        if error.Fail():
            raise RuntimeError('detach failed: ' + str(error))
    lldb.SBDebugger.Destroy(debugger)
    print('TASK8_V4_SCOPED_AMFI_CLEANUP_DONE', flush=True)

"""Temporary T03 driver; one authorized CDHash, no persistent configuration."""
import json
from pathlib import Path
import sys

AUTHORIZED = '343c11ebfeab191227fe5e6b849897282c2289c7'
BINARY = Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/acceptance/B15/candidate.app/Contents/MacOS/vphone-vm')
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, '/Users/qcz3840/Library/Python/3.9/lib/python/site-packages')
import amfidont.config_store as store
store.CONFIG_DIR = ROOT / 'config'
store.PATHS_FILE = store.CONFIG_DIR / 'paths'
store.CDHASHES_FILE = store.CONFIG_DIR / 'cdhashes'
store.load_persistent_config.__defaults__ = (store.CONFIG_DIR,)
config = store.load_persistent_config()
assert config == {'paths': [], 'cdhashes': []}, 'temporary config must be empty'
print(json.dumps({'paths': [], 'cdhashes': [AUTHORIZED], 'allow_all': False,
                  'spoof_apple': True, 'config_dir': str(store.CONFIG_DIR)}), flush=True)
if sys.argv[1:] == ['--check-config']:
    raise SystemExit(0)
assert not sys.argv[1:], 'no arguments that can broaden scope'
import subprocess
signature = subprocess.run(['/usr/bin/codesign','-d','--verbose=4',str(BINARY)], capture_output=True,text=True,check=True).stderr
assert 'CDHash=' + AUTHORIZED + '\n' in signature, 'candidate CDHash changed'
from amfidont import bypass_runtime as runtime
lldb = runtime.lldb
debugger = lldb.SBDebugger.Create()
debugger.SetAsync(False)
target = debugger.CreateTarget('')
process = None
try:
    error = lldb.SBError()
    process = target.AttachToProcessWithName(debugger.GetListener(), runtime.AMFID_PATH, False, error)
    if error.Fail() or not process.IsValid():
        raise RuntimeError('attach failed: ' + str(error))
    for name in ('-[AMFIPathValidator_macos validateWithError:]', '-[AMFIPathValidator_macos isApple]'):
        bp = target.BreakpointCreateByName(name)
        if bp.GetNumLocations() == 0:
            raise RuntimeError('breakpoint not resolved: ' + name)
    print('SCOPED_AMFID_READY pid=' + str(process.GetProcessID()), flush=True)
    runtime.bypass_loop(process,target,paths=[],cdhashes=[AUTHORIZED],verbose=False,allow_all=False,spoof_apple=True)
except KeyboardInterrupt:
    print('SCOPED_AMFID_STOP_REQUESTED', flush=True)
finally:
    if process is not None and process.IsValid():
        stop_error = process.Stop()
        target.DeleteAllBreakpoints()
        detach_error = process.Detach()
        print('SCOPED_AMFID_DETACH ' + str(detach_error), flush=True)
        if detach_error.Fail():
            raise RuntimeError('detach failed: ' + str(detach_error))
    lldb.SBDebugger.Destroy(debugger)
    print('SCOPED_AMFID_CLEANUP_DONE', flush=True)

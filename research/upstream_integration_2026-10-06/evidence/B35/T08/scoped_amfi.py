#!/usr/bin/env python3
"""B35 单一冻结 CDHash 验证驱动；--check 只核对输入，--run 须另获用户批准。"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[5]
BINARY = REPO / '.build/research-b35/source/.build/vphone-cli.app/Contents/MacOS/vphone-vm'
SHA256 = 'a4f8a4155a95e3d0c9067f856bb09a165df22cc9e55fcf9356f01ab16b0d11f4'
CDHASH = '62026af109b33fdd468c2c2df2fcdb4211136bf0'
MODULES = Path('/Users/kolar/Library/Python/3.9/lib/python/site-packages')
assert sys.argv[1:] in [['--check'], ['--run']], 'only --check or --run allowed'
assert not BINARY.is_symlink() and hashlib.sha256(BINARY.read_bytes()).hexdigest() == SHA256
display = subprocess.run(['codesign', '-d', '--verbose=4', str(BINARY)], check=True,
                         capture_output=True, text=True).stderr
assert 'CDHash=' + CDHASH + '\n' in display
assert (MODULES / 'amfidont/bypass_runtime.py').is_file()
scope = dict(binary=str(BINARY), sha256=SHA256, cdhashes=[CDHASH], paths=[],
             allow_all=False, spoof_apple=True, persistent_config=False)
print(json.dumps(scope), flush=True)
if sys.argv[1:] == ['--check']:
    sys.exit(0)
assert os.geteuid() == 0, 'administrator execution required'
fs = os.statvfs(REPO)
assert fs.f_bavail * fs.f_frsize >= 5 * 1024**3, 'STOP: disk below 5 GiB'
sys.path.insert(0, str(MODULES))
from amfidont import bypass_runtime as runtime

# 此进程始终提供空配置；不读取或重载任何用户的持久路径/CDHash 列表。
runtime.load_persistent_config = lambda: {'paths': [], 'cdhashes': []}
runtime.config_modified_time_state = lambda: (None, None)
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
        breakpoint = target.BreakpointCreateByName(name)
        if breakpoint.GetNumLocations() == 0:
            raise RuntimeError('breakpoint not resolved: ' + name)
    print('B35_SCOPED_AMFI_READY pid=' + str(process.GetProcessID()), flush=True)
    runtime.bypass_loop(process, target, paths=[], cdhashes=[CDHASH], verbose=False,
                        allow_all=False, spoof_apple=True)
except KeyboardInterrupt:
    print('B35_SCOPED_AMFI_STOP_REQUESTED', flush=True)
finally:
    if process is not None and process.IsValid():
        process.Stop()
        target.DeleteAllBreakpoints()
        error = process.Detach()
        print('B35_SCOPED_AMFI_DETACH ' + str(error), flush=True)
        if error.Fail():
            raise RuntimeError('detach failed: ' + str(error))
    lldb.SBDebugger.Destroy(debugger)
    print('B35_SCOPED_AMFI_CLEANUP_DONE', flush=True)

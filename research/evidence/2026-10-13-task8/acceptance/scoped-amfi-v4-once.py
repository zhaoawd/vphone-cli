"""Single authorized V4 exec; detach at its existing stopped hook state."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

BINARY = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-vm')
SHA256 = '0e5944b2b79aaa059af156cb47824c399183d970a93db35b839b5dda39b31ca1'
CDHASH = '43c00d51b4c7f07a5feba006f3c244edbac39cea'
MODULES = Path('/Users/qcz3840/Library/Python/3.9/lib/python/site-packages')
RUNTIME_SHA256 = 'bd418fcb2732c08162a115b8537fa4cde8cbb4212bc2361e9113decf8325bab0'


def log(event, **record):
    print('TASK8_V4_ONCE_' + event + ' ' + json.dumps(record), flush=True)


def run_one_exec(runtime, process, target):
    """Keep original synchronous hooks and stop after both matched results."""
    seen = set()
    observations = []
    original_dump = runtime.dump_validator
    captured = []

    def capture(*args, **kwargs):
        result = original_dump(*args, **kwargs)
        captured.append(dict(result))
        return result

    runtime.dump_validator = capture
    try:
        while seen != {'validate', 'isApple'}:
            error = process.Continue()
            if error.Fail():
                raise RuntimeError('Continue failed: ' + str(error))
            if process.GetState() != runtime.lldb.eStateStopped:
                raise RuntimeError('Inferior did not return at a stopped hook')
            thread = runtime.get_stopped_thread(process, runtime.lldb.eStopReasonBreakpoint)
            if thread is None:
                raise RuntimeError('Inferior stopped without a configured breakpoint')
            name = thread.frames[0].GetFunctionName() or ''
            if 'isApple' in name:
                kind, hook = 'isApple', runtime.is_apple_hook
            elif 'validateWithError:' in name:
                kind, hook = 'validate', runtime.validate_hook
            else:
                raise RuntimeError('Unexpected breakpoint function: ' + name)
            captured.clear()
            hook(target, thread, paths=set(), cdhashes={CDHASH}, verbose=True, allow_all=False)
            if len(captured) != 1 or process.GetState() != runtime.lldb.eStateStopped:
                raise RuntimeError('Hook did not finish synchronously in stopped state')
            record = captured[0]
            record.update(hook=kind, stopped=True)
            if record['cdhash'] == CDHASH:
                return_register, _ = runtime.registers_for_target(target)
                value = int(thread.frames[0].reg[return_register].value, 0)
                record['return_value'] = value
                if value != 1:
                    raise RuntimeError('Authorized hook result did not read back as true')
                seen.add(kind)
            observations.append(record)
            log('HOOK', **record)
        return observations
    finally:
        runtime.dump_validator = original_dump


def cleanup_existing_stop(lldb, process, target):
    """Never request a new stop; return whether debugger destruction is safe."""
    state = process.GetState()
    result = {'state': state, 'safe_destroy': False, 'error': None}
    log('EXIT_STATE', state=state, status=process.GetExitStatus(), description=process.GetExitDescription())
    if state == lldb.eStateStopped:
        deleted = False
        try:
            deleted = target.DeleteAllBreakpoints()
            log('DELETE_BREAKPOINTS', success=deleted)
        except Exception as error:
            log('DELETE_BREAKPOINTS', success=False, error=str(error))
        try:
            error = process.Detach(False)
            log('DETACH', success=error.Success(), error=str(error), keep_stopped=False)
            result['safe_destroy'] = error.Success()
            if error.Fail():
                result['error'] = 'detach failed: ' + str(error)
            elif not deleted:
                result['error'] = 'DeleteAllBreakpoints failed; inferior detached'
        except Exception as error:
            result['error'] = 'detach raised: ' + str(error)
    elif state in (lldb.eStateExited, lldb.eStateDetached):
        result['safe_destroy'] = True
    else:
        result['error'] = 'Cleanup requires an existing stopped state; no new pause is authorized'
    return result


def main():
    assert sys.argv[1:] in [['--check'], ['--run']]
    assert not BINARY.is_symlink() and hashlib.sha256(BINARY.read_bytes()).hexdigest() == SHA256
    signature = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(BINARY)], capture_output=True, text=True, check=True).stderr
    assert 'CDHash=' + CDHASH + '\n' in signature
    assert hashlib.sha256((MODULES / 'amfidont/bypass_runtime.py').read_bytes()).hexdigest() == RUNTIME_SHA256
    log('SCOPE', binary=str(BINARY), sha256=SHA256, cdhashes=[CDHASH], paths=[],
        allow_all=False, spoof_apple=True, persistent_config=False,
        driver_pid=os.getpid(), permitted_vm='/private/tmp/vphone-task8-acceptance-vms/task8-copy',
        cleanup='both authorized hooks -> delete breakpoints -> detach(false); no Stop request')
    if sys.argv[1:] == ['--check']:
        return
    assert os.geteuid() == 0
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(MODULES))
    from amfidont import bypass_runtime as runtime
    lldb = runtime.lldb
    debugger = lldb.SBDebugger.Create()
    debugger.SetAsync(False)
    target = debugger.CreateTarget('')
    process = None
    attached = False

    def interrupt(_signal, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupt)
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
        log('READY', amfid_pid=process.GetProcessID())
        observations = run_one_exec(runtime, process, target)
        log('COMPLETE', matched_hooks=sorted({r['hook'] for r in observations if r['cdhash'] == CDHASH}))
    finally:
        cleanup = {'safe_destroy': not attached, 'error': None}
        if attached:
            if process is not None and process.IsValid():
                cleanup = cleanup_existing_stop(lldb, process, target)
            else:
                cleanup = {'safe_destroy': False, 'error': 'Attached process state unavailable'}
        if cleanup['safe_destroy']:
            lldb.SBDebugger.Destroy(debugger)
            log('CLEANUP_DONE')
        if cleanup['error']:
            raise RuntimeError(cleanup['error'])


if __name__ == '__main__':
    main()

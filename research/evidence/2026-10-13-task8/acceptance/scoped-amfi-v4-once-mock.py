"""Pure mocks: no LLDB import, attach, VM execution or system signals."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace as NS

path = Path(__file__).with_name('scoped-amfi-v4-once.py')
spec = importlib.util.spec_from_file_location('scoped_once', path)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def case(order, bad_return=False, bad_state=False, incomplete=False):
    calls = []
    process = NS(current=None, cursor=0, state=2)
    def resume():
        if process.cursor >= len(order):
            raise RuntimeError('mock input ended before both hooks; real Continue can still block')
        process.current = order[process.cursor]
        process.cursor += 1
        process.state = 1 if bad_state else 2
        calls.append('Continue')
        return NS(Fail=lambda: False)
    process.Continue = resume
    process.GetState = lambda: process.state
    runtime = NS(lldb=NS(eStateStopped=2, eStopReasonBreakpoint=3))
    def dump(_target, _validator):
        return {'path': str(driver.BINARY), 'cdhash': process.current[1], 'is_valid': False}
    runtime.dump_validator = dump
    def thread_for(_process, reason):
        assert reason == 3
        kind = process.current[0]
        frame = NS(GetFunctionName=lambda: '-[AMFIPathValidator_macos ' + ('isApple' if kind == 'isApple' else 'validateWithError:') + ']',
                   reg={'x0': NS(value='0')})
        return NS(frames=[frame])
    runtime.get_stopped_thread = thread_for
    runtime.registers_for_target = lambda _target: ('x0', 'x0')
    def hook(target, thread, **flags):
        assert flags == {'paths': set(), 'cdhashes': {driver.CDHASH}, 'verbose': True, 'allow_all': False}
        result = runtime.dump_validator(target, 'validator')
        calls.append(process.current[0])
        if result['cdhash'] == driver.CDHASH:
            thread.frames[0].reg['x0'].value = '0' if bad_return else '1'
    runtime.validate_hook = hook
    runtime.is_apple_hook = hook
    try:
        observations = driver.run_one_exec(runtime, process, NS())
        assert not bad_return and not bad_state and not incomplete
        assert {r['hook'] for r in observations if r['cdhash'] == driver.CDHASH} == {'validate', 'isApple'}
        assert process.cursor == len(order)
    except RuntimeError:
        assert bad_return or bad_state or incomplete
    assert runtime.dump_validator is dump
    assert all(name in ('Continue', 'validate', 'isApple') for name in calls)
    return {'order': order, 'bad_return': bad_return, 'bad_state': bad_state, 'incomplete': incomplete, 'passed': True}


def cleanup_case(state, deleted=True, detach_success=True, deletion_raises=False):
    calls = []
    lldb = NS(eStateStopped=2, eStateExited=3, eStateDetached=4)
    def delete():
        calls.append('DeleteAllBreakpoints')
        if deletion_raises:
            raise RuntimeError('mock deletion failure')
        return deleted
    def detach(keep_stopped):
        assert keep_stopped is False
        calls.append('Detach(false)')
        return NS(Success=lambda: detach_success, Fail=lambda: not detach_success)
    target = NS(DeleteAllBreakpoints=delete)
    process = NS(GetState=lambda: state, GetExitStatus=lambda: 0,
                 GetExitDescription=lambda: '', Detach=detach)
    result = driver.cleanup_existing_stop(lldb, process, target)
    if result['safe_destroy']:
        calls.append('Destroy')
    if state == 2:
        assert calls[:2] == ['DeleteAllBreakpoints', 'Detach(false)']
        assert result['safe_destroy'] == detach_success
        assert (result['error'] is not None) == (not detach_success or not deleted or deletion_raises)
    elif state in (3, 4):
        assert calls == ['Destroy'] and result['error'] is None
    else:
        assert calls == [] and result['error'] is not None and not result['safe_destroy']
    assert 'Stop' not in calls
    return {'state': state, 'deleted': deleted, 'detach_success': detach_success,
            'deletion_raises': deletion_raises, 'calls': calls, 'result': result, 'passed': True}


c = driver.CDHASH
results = [case([('validate', c), ('isApple', c)]),
           case([('isApple', c), ('validate', c)]),
           case([('validate', '0' * 40), ('validate', c), ('isApple', c)]),
           case([('validate', c)], bad_return=True),
           case([('validate', c)], bad_state=True),
           case([('validate', c)], incomplete=True),
           case([('validate', c), ('validate', c)], incomplete=True)]
cleanup_results = [cleanup_case(2), cleanup_case(2, deleted=False),
                   cleanup_case(2, detach_success=False), cleanup_case(2, deletion_raises=True),
                   cleanup_case(1), cleanup_case(3), cleanup_case(4), cleanup_case(0)]
out = Path(__file__).with_name('scoped-amfi-v4-once-mock-v2.json')
assert not out.exists()
out.write_text(json.dumps({'passed': True, 'scope': 'pure mocks only', 'cases': results,
                          'cleanup_cases': cleanup_results,
                          'limitation': 'Missing hook can leave real synchronous Continue blocked; successful launch path only.'}, indent=2) + '\n')
print(json.dumps({'passed': True, 'cases': len(results), 'cleanup_cases': len(cleanup_results)}))

"""Pure operation mocks and ordinary temporary files; never observe/signal a PID."""
import copy
import hashlib
import importlib.util
import json
import os
import io
from contextlib import redirect_stdout
from unittest.mock import patch
from pathlib import Path
import signal
import sys
import tempfile
from types import SimpleNamespace as NS
import unittest

E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('restore_amfid', E / 'restore-acceptance-amfid.py')
helper = importlib.util.module_from_spec(spec); sys.modules[spec.name] = helper; spec.loader.exec_module(helper)
LABEL = 'kernel-v9-plan-r-mock'
PID = 12345
BIRTH = 2_000_000_000_000_000_000


def encoded(value):
    return json.dumps(value, sort_keys=True).encode()


def observation(state=helper.SSTOP, xstatus=int(signal.SIGSTOP), **changes):
    result = dict(flags=0, bsd_state=state, xstatus=xstatus, pid=PID, ppid=1, uid=0,
                  path=helper.AMFID, start_seconds=1_999_999_999, start_microseconds=100)
    result.update(changes)
    return result


class Operations:
    def __init__(self):
        self.uid = 0; self.signals = []; self.observations = [observation(), observation(), observation(helper.SRUN, 19)]
        self.events = [
            ('SCOPE', dict(binary=helper.BINARY, sha256=helper.BINARY_SHA256, cdhashes=[helper.CDHASH], paths=[],
                allow_all=False, spoof_apple=True, persistent_config=False, driver_pid=333, permitted_vm=helper.VM,
                cleanup='both authorized hooks -> delete breakpoints -> detach(false); no Stop request')),
            ('READY', {'amfid_pid': PID}),
            ('HOOK', {'path': helper.BINARY.replace(' ', '%20'), 'cdhash': helper.CDHASH, 'is_valid': False,
                'hook': 'validate', 'stopped': True, 'return_value': 1}),
            ('HOOK', {'path': helper.BINARY.replace(' ', '%20'), 'cdhash': helper.CDHASH, 'is_valid': False,
                'hook': 'isApple', 'stopped': True, 'return_value': 1}),
            ('COMPLETE', {'matched_hooks': ['isApple', 'validate']}),
            ('EXIT_STATE', {'state': 5, 'status': -1, 'description': None}),
            ('DELETE_BREAKPOINTS', {'success': True}),
            ('DETACH', {'success': True, 'error': 'success', 'keep_stopped': False}),
            ('CLEANUP_DONE', {})]
        self.result = dict(command=['sudo', '-n', '/usr/bin/python3', str(helper.DRIVER), '--run'],
                           exit_code=0, elapsed_seconds=1.0, log=LABEL + '-amfi-once.log')
        self.frozen_bad = None; self.read_count = {}; self.changed_on_reread = None
        self.observe_calls = 0; self.signal_error = False; self.seen_paths = []

    def euid(self):
        return self.uid

    def read(self, path):
        self.seen_paths.append(path)
        self.read_count[path] = self.read_count.get(path, 0) + 1
        if path == helper.DRIVER:
            data, digest = b'fixed mocked driver', helper.DRIVER_SHA256
        elif path == helper.RUNTIME:
            data, digest = b'fixed mocked runtime', helper.RUNTIME_SHA256
        elif path.name == LABEL + '-amfi-once.json':
            data = encoded(self.result); digest = hashlib.sha256(data).hexdigest()
        elif path.name == LABEL + '-amfi-once.log':
            data = ('\n'.join(helper.PREFIX + event + ' ' + json.dumps(value) for event, value in self.events) + '\n').encode()
            digest = hashlib.sha256(data).hexdigest()
        else:
            raise RuntimeError('Unexpected artifact path')
        if path == self.frozen_bad:
            digest = '0' * 64
        if path == self.changed_on_reread and self.read_count[path] > 1:
            data += b'changed'
        return helper.Blob(data, BIRTH, (1, 2, len(data), 3, 4, 0o100644, 1), digest)

    def observe(self, pid):
        assert pid == PID
        self.observe_calls += 1
        if not self.observations:
            raise RuntimeError('gone')
        value = self.observations.pop(0)
        if isinstance(value, Exception):
            raise value
        return copy.deepcopy(value)

    def send_continue(self, pid):
        assert pid == PID
        self.signals.append((pid, signal.SIGCONT))
        if self.signal_error:
            raise PermissionError('mock CONT denied')

    def wait(self):
        pass


class RestoreTests(unittest.TestCase):
    def execute(self, operations, passed):
        result = helper.restore(LABEL, operations)
        self.assertEqual(result['passed'], passed, result)
        self.assertTrue(all(pid == PID and sig == signal.SIGCONT for pid, sig in operations.signals))
        self.assertLessEqual(len(operations.signals), 1)
        return result

    def test_stopped_after_successful_detach_is_resumed(self):
        operations = Operations()
        result = self.execute(operations, True)
        self.assertEqual(operations.signals, [(PID, signal.SIGCONT)])
        self.assertEqual(result['before']['bsd_state'], helper.SSTOP)
        self.assertEqual(result['after']['bsd_state'], helper.SRUN)

    def test_running_is_recorded_without_signal(self):
        operations = Operations(); operations.observations = [observation(helper.SRUN, 19)] * 2
        result = self.execute(operations, True)
        self.assertEqual(operations.signals, []); self.assertIn('already-running', result['action'])

    def test_evidence_rejections_never_signal(self):
        changes = {
            'nonroot': lambda o: setattr(o, 'uid', 501),
            'driver': lambda o: setattr(o, 'frozen_bad', helper.DRIVER),
            'runtime': lambda o: setattr(o, 'frozen_bad', helper.RUNTIME),
            'exit': lambda o: o.result.update(exit_code=1),
            'bool-exit': lambda o: o.result.update(exit_code=False),
            'command': lambda o: o.result['command'].append('--check'),
            'log-path': lambda o: o.result.update(log='../other.log'),
            'scope-cdhash': lambda o: o.events[0][1].update(cdhashes=[helper.CDHASH, '0' * 40]),
            'scope-all': lambda o: o.events[0][1].update(allow_all=True),
            'scope-bool-type': lambda o: o.events[0][1].update(allow_all=0),
            'scope-paths': lambda o: o.events[0][1].update(paths=[helper.BINARY]),
            'scope-vm': lambda o: o.events[0][1].update(permitted_vm='/other'),
            'ready-duplicate': lambda o: o.events.insert(2, copy.deepcopy(o.events[1])),
            'ready-type': lambda o: o.events[1][1].update(amfid_pid=True),
            'hook-return': lambda o: o.events[2][1].update(return_value=0),
            'hook-return-bool': lambda o: o.events[2][1].update(return_value=True),
            'hook-path': lambda o: o.events[2][1].update(path='/other'),
            'hook-missing': lambda o: o.events.pop(2),
            'breakpoint': lambda o: o.events[-3][1].update(success=False),
            'breakpoint-bool-type': lambda o: o.events[-3][1].update(success=1),
            'detach': lambda o: o.events[-2][1].update(success=False),
            'keep-stopped': lambda o: o.events[-2][1].update(keep_stopped=True),
            'cleanup-missing': lambda o: o.events.pop(),
            'artifact-race': lambda o: setattr(o, 'changed_on_reread', helper.DRIVER),
        }
        for fault, change in changes.items():
            with self.subTest(fault=fault):
                operations = Operations(); change(operations)
                self.execute(operations, False); self.assertEqual(operations.signals, [])

    def test_native_preconditions_reject_without_signal(self):
        faults = [dict(uid=1), dict(ppid=2), dict(path='/other'), dict(pid=PID+1), dict(flags=2),
                  dict(start_seconds=2_000_000_001), dict(start_microseconds=1_000_000),
                  dict(bsd_state=0), dict(bsd_state=3), dict(bsd_state=5), dict(xstatus=19)]
        for fault in faults:
            with self.subTest(fault=fault):
                operations = Operations(); operations.observations[0].update(fault)
                self.execute(operations, False); self.assertEqual(operations.signals, [])

    def test_final_pre_signal_guard_rejects_reuse_trace_state_and_gone(self):
        faults = [observation(start_microseconds=200), observation(helper.SRUN), observation(flags=2), RuntimeError('gone')]
        for fault in faults:
            with self.subTest(fault=fault):
                operations = Operations(); operations.observations[1] = fault
                self.execute(operations, False); self.assertEqual(operations.signals, [])

    def test_after_signal_failures_record_failure_without_another_signal(self):
        faults = [observation(start_microseconds=200), observation(flags=2), observation(bsd_state=3), RuntimeError('gone')]
        for fault in faults:
            with self.subTest(fault=fault):
                operations = Operations(); operations.observations[2] = fault
                result = self.execute(operations, False)
                self.assertEqual(len(operations.signals), 1); self.assertEqual(result['signals_sent'][0]['signal'], 'SIGCONT')

    def test_single_continue_can_wait_for_running_readback(self):
        operations = Operations(); operations.observations = [observation()] * 4 + [observation(helper.SRUN, 19)]
        self.execute(operations, True); self.assertEqual(len(operations.signals), 1)

    def test_still_stopped_is_bounded_failure(self):
        operations = Operations(); operations.observations = [observation()] * 22
        self.execute(operations, False); self.assertEqual(operations.observe_calls, 22)

    def test_signal_failure_does_not_report_sent(self):
        operations = Operations(); operations.signal_error = True
        result = self.execute(operations, False)
        self.assertEqual(result['signals_sent'], []); self.assertEqual(result['signals_attempted'][0]['signal'], 'SIGCONT')

    def test_native_adapter_abi_and_signal_are_mocked(self):
        class Function:
            def __init__(self, body): self.body = body
            def __call__(self, *arguments): return self.body(*arguments)
        for fault in ('success', 'short-info', 'bad-path-length', 'identity-race', 'traced'):
            calls = []; observation_count = 0
            def info(pid, flavor, offset, pointer, size):
                nonlocal observation_count
                calls.append(('info', pid, flavor, size)); observation_count += 1
                self.assertEqual((pid, flavor, size), (PID, 3, 136))
                value = observation()
                if fault == 'identity-race' and observation_count == 2: value['start_microseconds'] += 1
                if fault == 'traced': value['flags'] = 2
                for key, item in value.items():
                    if key != 'path': setattr(pointer._obj, key, item)
                return 0 if fault == 'short-info' else 136
            def path(pid, buffer, size):
                calls.append(('path', pid)); buffer.value = helper.AMFID.encode()
                return size if fault == 'bad-path-length' else len(buffer.value)
            fake = NS(proc_pidinfo=Function(info), proc_pidpath=Function(path))
            with self.subTest(fault=fault), patch.object(helper.ctypes, 'CDLL', return_value=fake):
                if fault == 'success': self.assertEqual(helper.NativeOperations().observe(PID), observation())
                else:
                    with self.assertRaises(Exception): helper.NativeOperations().observe(PID)
            self.assertTrue(calls)
        with patch.object(helper.os, 'kill') as kill:
            helper.NativeOperations().send_continue(PID)
            kill.assert_called_once_with(PID, signal.SIGCONT)

    def test_exclusive_output_and_failure_record(self):
        with tempfile.TemporaryDirectory(prefix='task8-amfid-output-mock-') as folder:
            for passed in (True, False):
                operations = Operations()
                if not passed: operations.uid = 501
                path = Path(folder) / (LABEL + '-amfi-restore-check.json')
                if path.exists(): path.unlink()
                with patch.object(helper, 'E', Path(folder)), patch.object(helper, 'NativeOperations', return_value=operations), redirect_stdout(io.StringIO()):
                    self.assertEqual(helper.main([LABEL]), 0 if passed else 1)
                    result = json.loads(path.read_bytes()); self.assertEqual(result['passed'], passed)
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    exact = path.read_bytes(); seen = len(operations.seen_paths)
                    with self.assertRaises(FileExistsError): helper.main([LABEL])
                    self.assertEqual(path.read_bytes(), exact)
                    self.assertEqual(len(operations.seen_paths), seen)

    def test_invalid_labels_json_and_exact_file_metadata(self):
        for label in ('../escape', 'A', '', 'x/y', 'x' * 81, '-x', 'x-'):
            operations = Operations(); result = helper.restore(label, operations)
            self.assertFalse(result['passed']); self.assertEqual(operations.seen_paths, []); self.assertEqual(operations.signals, [])
        for data in (b'{"pid":1,"pid":2}', b'{"pid":NaN}', b'[]'):
            with self.assertRaises(Exception): helper.json_object(data)
        # Ordinary temporary-file metadata only; no process API is involved.
        with tempfile.TemporaryDirectory(prefix='task8-restore-amfid-mock-') as folder:
            path = Path(folder) / 'log'; path.write_bytes(b'ordinary temporary file')
            blob = helper.strict_blob(path)
            self.assertEqual(blob.sha256, hashlib.sha256(path.read_bytes()).hexdigest()); self.assertGreater(blob.birth_ns, 0)
            link = Path(folder) / 'link'; link.symlink_to(path)
            with self.assertRaises(Exception): helper.strict_blob(link)
            hardlink = Path(folder) / 'hardlink'; os.link(path, hardlink)
            with self.assertRaises(Exception): helper.strict_blob(path)


def legacy_red():
    spec = importlib.util.spec_from_file_location('fixed_driver', helper.DRIVER)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    bsd = observation()
    process = NS(GetState=lambda: 5, GetExitStatus=lambda: -1, GetExitDescription=lambda: None,
                 Detach=lambda keep: NS(Success=lambda: True, Fail=lambda: False))
    report = module.cleanup_existing_stop(NS(eStateStopped=5, eStateExited=10, eStateDetached=9), process, NS(DeleteAllBreakpoints=lambda: True))
    assert report['safe_destroy'] is True
    # Real fixed-driver cleanup succeeds while the independent BSD observation
    # remains SSTOP. The new postcondition is intentionally RED here.
    assert bsd['bsd_state'] == helper.SRUN, 'Detach(false) success did not establish BSD SRUN (mock remains SSTOP=4)'


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    if sys.argv[1:] == ['--legacy-red']:
        legacy_red()
    else:
        unittest.main()

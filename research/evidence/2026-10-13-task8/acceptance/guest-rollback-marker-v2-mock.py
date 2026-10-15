"""Pure CLI-operation mocks plus ordinary temporary evidence files; no guest call."""
import base64
import copy
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch

E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('guest_marker_v2', E / 'guest-rollback-marker-v2.py')
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
BOOT, LABEL, NEXT_BOOT, NEXT_LABEL = 'source-boot', 'marker-evidence', 'next-boot', 'read-evidence'
TOKEN = '12345678-1234-4234-8234-123456789abc'
GENERATION = 'd' * 64


class Operations:
    def __init__(self, files=None):
        self.guest_files = {} if files is None else files
        self.files = {}; self.messages = []; self.intents = {}; self.pending_value = False
        self.fault = None; self.sync_path = '/bin/sync'; self.intent_record = None
        self.prepare(BOOT, 1)

    def prepare(self, boot_label, instance):
        self.target = dict(vm='task8-copy', instance_id=('11111111-1111-4111-8111-111111111111' if instance == 1 else '22222222-2222-4222-8222-222222222222'),
                           pid=100+instance, process_started_at=1000.0+instance)
        binding = {'bundle': helper.HOST, 'kernel': '2.6.20261021-local'}
        receipt = {'schemaVersion': 1, 'transactionID': ('33333333-3333-4333-8333-333333333333' if instance == 1 else '44444444-4444-4444-8444-444444444444'),
                   'installed': {'scope': 'installedComponent', 'state': 'committed', 'component': 'kernelcache', 'generationID': GENERATION}}
        desired = {'schemaVersion': 1, 'generationID': GENERATION, 'planSHA256': 'b' * 64}
        for name, value in [('launchpad.json', binding), ('.firmware-component-receipts.json', receipt), ('.firmware-desired-plan.json', desired)]:
            self.files[helper.VM / name] = helper.canonical(value)
        self.files[helper.VM / 'config.plist'] = plistlib.dumps({'machineIdentifier': b'stable machine identity'})
        expected = dict(binding=binding, binding_sha256=helper.sha(self.files[helper.VM / 'launchpad.json']),
            receipt_sha256=helper.sha(self.files[helper.VM / '.firmware-component-receipts.json']),
            desired_sha256=helper.sha(self.files[helper.VM / '.firmware-desired-plan.json']), transaction_id=receipt['transactionID'], payload_sha256=('a' if instance == 1 else 'c') * 64)
        self.files[helper.E / (boot_label + '-boot-watch.json')] = helper.canonical({'passed': True, 'target': self.target, 'expected': expected})
        self.expected = expected

    def read(self, path): return self.files[path]
    def pending(self): return self.pending_value
    def new_uuid(self): return TOKEN
    def intent(self, label, marker):
        if label in self.intents: raise FileExistsError('mock exclusive intent')
        self.intents[label] = copy.deepcopy(marker); self.intent_record = marker
    def request(self, message):
        self.messages.append(copy.deepcopy(message)); kind = message['t']
        assert message['target'] == self.target
        if kind == 'capabilities':
            response = dict(ok=True, target=self.target, guest_connected=True, boot_mode='normal', commands={'shell': True, 'file_get': True})
            if self.fault == 'wrong-instance': response['target'] = dict(self.target, pid=900)
            if self.fault == 'guest-disconnected': response['guest_connected'] = False
        elif kind == 'shell':
            cmd = message['cmd']; response = dict(ok=True, code=0, timed_out=False, truncated=False, stdout='', stderr='')
            if cmd == helper.PROBE:
                response['stdout'] = self.sync_path + '\n'
                if self.fault == 'no-sync': response['code'] = 69
                if self.fault == 'probe-extra': response['stdout'] += 'unexpected\n'
            elif cmd.startswith('(set -C && printf %s '):
                marker = self.intent_record; data = base64.b64decode(marker['content_base64'], validate=True)
                expected = '(set -C && printf %s ' + shlex.quote(data.decode()) + ' > ' + shlex.quote(marker['path']) + ')'
                assert cmd == expected and marker['path'].startswith(helper.DIRECTORY + '/task8-kernel-rollback-')
                if marker['path'] in self.guest_files or self.fault == 'write-code': response['code'] = 1
                else: self.guest_files[marker['path']] = data
            elif cmd == 'exec ' + self.sync_path:
                assert self.intent_record['path'] in self.guest_files
                for fault, key, value in [('sync-code', 'code', 1), ('sync-timeout', 'timed_out', True), ('sync-truncated', 'truncated', True)]:
                    if self.fault == fault: response[key] = value
            else: raise AssertionError('Unexpected shell command')
        elif kind == 'file_get':
            assert message['path'].startswith(helper.DIRECTORY + '/task8-kernel-rollback-')
            data = self.guest_files.get(message['path'])
            if data is None or self.fault == 'missing': response = dict(ok=False, error='open failed: No such file or directory')
            else:
                if self.fault == 'bytes': data += b'x'
                response = dict(ok=True, size=len(data), data=base64.b64encode(data).decode())
                if self.fault == 'size': response['size'] += 1
                if self.fault == 'base64': response['data'] = '!invalid'
        else: raise AssertionError('Unsupported request type')
        if self.fault == 'desired-race' and len(self.messages) == 3:
            self.files[helper.VM / '.firmware-desired-plan.json'] += b'changed'
        return dict(command=helper.cli_command(message), exit_code=0 if response.get('ok') is True else 1,
                    stdout=json.dumps(response), stderr='', host_timed_out=self.fault == 'host-timeout')


def create(operations=None):
    operations = operations or Operations()
    return operations, helper.perform('create', BOOT, LABEL, None, operations)


def read_setup():
    operations, previous = create(); assert previous['passed']
    operations.files[helper.E / (LABEL + '-marker-v2-create.json')] = helper.canonical(previous)
    operations.prepare(NEXT_BOOT, 2); operations.messages = []
    return operations, previous


class MarkerTests(unittest.TestCase):
    def test_create_documents_sync_then_actual_readback(self):
        for sync in helper.SYNC_PATHS:
            with self.subTest(sync=sync):
                operations = Operations(); operations.sync_path = sync
                _, result = create(operations); self.assertTrue(result['passed'], result)
                self.assertEqual([m['t'] for m in operations.messages], ['capabilities', 'shell', 'shell', 'shell', 'file_get', 'capabilities'])
                self.assertEqual(operations.messages[1]['cmd'], helper.PROBE)
                self.assertTrue(operations.messages[2]['cmd'].startswith('(set -C && printf %s '))
                self.assertEqual(operations.messages[3]['cmd'], 'exec ' + sync)
                self.assertEqual(operations.messages[4]['path'], helper.DIRECTORY + '/task8-kernel-rollback-' + TOKEN)
                self.assertEqual(result['downloaded_sha256'], helper.sha(operations.guest_files[result['marker']['path']]))
                self.assertEqual(result['boot_label'], BOOT); self.assertEqual(result['evidence_label'], LABEL)

    def test_read_uses_new_instance_and_preserves_target_plan_vs_live_desired(self):
        operations, previous = read_setup()
        result = helper.perform('read', NEXT_BOOT, NEXT_LABEL, LABEL, operations)
        self.assertTrue(result['passed'], result); self.assertEqual(result['downloaded_sha256'], previous['downloaded_sha256'])
        self.assertNotEqual(result['expected']['transaction_id'], previous['expected']['transaction_id'])
        self.assertEqual([m['t'] for m in operations.messages], ['capabilities', 'file_get', 'capabilities'])
        self.assertTrue(all(m['target'] == operations.target for m in operations.messages))

    def test_sync_and_write_failures_do_not_produce_qualified_create(self):
        for fault in ('no-sync', 'probe-extra', 'write-code', 'sync-code', 'sync-timeout', 'sync-truncated', 'host-timeout'):
            with self.subTest(fault=fault):
                operations = Operations(); operations.fault = fault
                _, result = create(operations); self.assertFalse(result['passed'])
                if fault in ('no-sync', 'probe-extra', 'host-timeout'): self.assertFalse(operations.guest_files)
                self.assertFalse(any(m['t'] == 'file_get' for m in operations.messages))

    def test_existing_marker_is_not_overwritten(self):
        path = helper.DIRECTORY + '/task8-kernel-rollback-' + TOKEN
        operations = Operations({path: b'original data'})
        _, result = create(operations); self.assertFalse(result['passed']); self.assertEqual(operations.guest_files[path], b'original data')

    def test_actual_readback_and_capability_failures(self):
        for fault in ('wrong-instance', 'guest-disconnected', 'missing', 'bytes', 'size', 'base64', 'desired-race'):
            with self.subTest(fault=fault):
                operations = Operations(); operations.fault = fault
                _, result = create(operations); self.assertFalse(result['passed'])

    def test_current_inputs_and_pending_are_checked_before_write(self):
        for name in ('launchpad.json', '.firmware-component-receipts.json', '.firmware-desired-plan.json', 'config.plist', 'pending'):
            with self.subTest(name=name):
                operations = Operations()
                if name == 'pending': operations.pending_value = True
                else: operations.files[helper.VM / name] = b'changed'
                _, result = create(operations); self.assertFalse(result['passed']); self.assertEqual(operations.messages, [])

    def test_previous_create_requires_documents_sync_bytes_and_provenance(self):
        mutations = {
            'failed': lambda p: p.update(passed=False),
            'old-tool': lambda p: p.update(schemaVersion=1),
            'old-tmp-path': lambda p: p['marker'].update(path='/private/var/tmp/task8-kernel-rollback-' + TOKEN),
            'arbitrary-path': lambda p: p['marker'].update(path='/private/var/mobile/Documents/other'),
            'uuid': lambda p: p['marker'].update(uuid='../escape'),
            'sha': lambda p: p['marker'].update(content_sha256='0' * 64),
            'size': lambda p: p['marker'].update(size=1),
            'bytes': lambda p: p['marker'].update(content_base64=base64.b64encode(b'forged').decode()),
            'sync-missing': lambda p: p.pop('sync'),
            'sync-code': lambda p: p['sync']['response'].update(code=1),
            'sync-path': lambda p: p['sync'].update(executable='/usr/bin/other'),
            'record-label': lambda p: p.update(evidence_label='other'),
            'sync-stdout': lambda p: p['requests'][3].update(stdout='{}'),
            'cli-command': lambda p: p['requests'][3]['command'].__setitem__(0, '/other'),
            'write-proof': lambda p: p['requests'][2]['response'].update(code=1),
            'get-proof': lambda p: p['requests'][4]['response'].update(data=base64.b64encode(b'other').decode()),
            'old-boot-proof': lambda p: p.update(source_boot_sha256='0' * 64),
            'machine': lambda p: p['vm_identity'].update(machine_identifier_sha256='0' * 64),
        }
        for fault, mutate in mutations.items():
            with self.subTest(fault=fault):
                operations, previous = read_setup(); mutate(previous)
                operations.files[helper.E / (LABEL + '-marker-v2-create.json')] = helper.canonical(previous)
                result = helper.perform('read', NEXT_BOOT, NEXT_LABEL, LABEL, operations)
                self.assertFalse(result['passed']); self.assertFalse(any(m['t'] == 'file_get' for m in operations.messages))

    def test_read_same_instance_and_other_machine_refused(self):
        for fault in ('same-instance', 'other-machine', 'same-start'):
            with self.subTest(fault=fault):
                operations, previous = read_setup()
                if fault == 'same-instance': operations.target = previous['target']
                if fault == 'same-start': operations.target['process_started_at'] = previous['target']['process_started_at']
                if fault == 'other-machine': operations.files[helper.VM / 'config.plist'] = plistlib.dumps({'machineIdentifier': b'other machine'})
                boot = helper.decode_json(operations.files[helper.E / (NEXT_BOOT + '-boot-watch.json')]); boot['target'] = operations.target
                operations.files[helper.E / (NEXT_BOOT + '-boot-watch.json')] = helper.canonical(boot)
                result = helper.perform('read', NEXT_BOOT, NEXT_LABEL, LABEL, operations)
                self.assertFalse(result['passed']); self.assertFalse(any(m['t'] == 'file_get' for m in operations.messages))

    def test_invalid_labels_and_duplicate_json(self):
        for bad in ('../escape', 'A', '', 'a/b', 'x' * 81):
            operations = Operations(); result = helper.perform('create', BOOT, bad, None, operations)
            self.assertFalse(result['passed']); self.assertEqual(operations.messages, [])
        with self.assertRaises(Exception): helper.decode_json(b'{"passed":true,"passed":false}')

    def test_native_request_adapter_is_only_mocked_cli(self):
        message = {'t': 'capabilities', 'target': Operations().target}
        with patch.object(helper.subprocess, 'run', return_value=NS(returncode=0, stdout='{}', stderr='')) as run:
            event = helper.NativeOperations().request(message)
            command = run.call_args.args[0]
            self.assertEqual(command[:3], [helper.CLI, 'guest', 'send'])
            self.assertEqual(command[3:8], ['task8-copy', '--library-root', str(helper.VM.parent), '--timeout', '75'])
            self.assertEqual(json.loads(command[-1]), message); self.assertFalse(event['host_timed_out'])
        with patch.object(helper.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['mock'], 90)):
            self.assertTrue(helper.NativeOperations().request(message)['host_timed_out'])

    def test_temp_files_and_exclusive_output(self):
        with tempfile.TemporaryDirectory(prefix='task8-marker-v2-mock-') as folder:
            path = Path(folder) / 'ordinary'; path.write_bytes(b'test')
            self.assertEqual(helper.strict_read(path), b'test')
            link = Path(folder) / 'link'; link.symlink_to(path)
            with self.assertRaises(Exception): helper.strict_read(link)
            with patch.object(helper, 'E', Path(folder)):
                operations = Operations()
                with patch.object(helper, 'NativeOperations', return_value=operations), redirect_stdout(io.StringIO()):
                    self.assertEqual(helper.main(['create', '--boot-label', BOOT, '--label', LABEL]), 0)
                    output = Path(folder) / (LABEL + '-marker-v2-create.json'); original = output.read_bytes()
                    requests = len(operations.messages)
                    with self.assertRaises(FileExistsError): helper.main(['create', '--boot-label', BOOT, '--label', LABEL])
                    self.assertEqual(output.read_bytes(), original); self.assertEqual(len(operations.messages), requests)


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    unittest.main()

"""Saved small-file/memory tests. Future R_B rows exist only in memory fixtures.

Never run verifier main, actual CLI, VM, Store, process API or signals.
"""
import base64
from collections import Counter
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('documents_verify', E / 'verify-documents-persistence.py')
m = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = m
spec.loader.exec_module(m)


class MemoryEvidence:
    def __init__(self, data): self.data, self.reads, self.changed = data, Counter(), None
    def read(self, name):
        self.reads[name] += 1
        if name not in self.data: raise FileNotFoundError(name)
        identity = (name, 1 if self.changed == name and self.reads[name] > 1 else 0)
        return m.Snapshot(self.data[name], identity)
    def json(self, name): return json.loads(self.data[name])
    def put(self, name, value): self.data[name] = (json.dumps(value, indent=2) + '\n').encode()


def saved_inputs():
    names = {'clone.json', 'baseline-digests.json', m.ORIGIN + '-marker-read.json', m.CREATE + '-marker-v2-create.json', m.CREATE + '-marker-v2-intent.json',
             m.REBOOT + '-pre-boot-check.json', m.REBOOT + '-v4-preflight.json', m.REBOOT + '-marker-v2-read.json'}
    for label in (m.ORIGIN, m.HISTORY):
        names.update(label + suffix for suffix in ('.json', '-readback.json', '-before.json', '-operation-expectations.json', '-committed-journal.json',
                     '-committed-report.json', '-committed-component-receipts.json', '-committed-installed-component-proof.json'))
    for label in (m.ORIGIN, m.REBOOT):
        names.update(label + suffix for suffix in ('-boot-expectations.json', '-boot-watch.json', '-vm-launch.json', '-vm-launch.log', '-vm-stop.json', '-vm-stop.log', '-post-boot-cleanup.json'))
    names.update(m.ROLLBACK + suffix for suffix in ('-before.json', '-before-receipt.json', '-before-binding.json', '-before-desired.json', '-operation-expectations.json',
                                                  '-source9-host-rebind-check.json', '-source9-binding-owner-check.json'))
    return MemoryEvidence({name: (E / name).read_bytes() for name in names})


def synthetic_complete():
    """Real frozen prerequisite shapes plus an explicitly synthetic in-memory R_B."""
    fixture = saved_inputs()
    label, history = m.ROLLBACK, m.HISTORY
    before = fixture.json(label + '-before.json')
    journal = fixture.json(history + '-committed-journal.json')
    proof = fixture.json(history + '-committed-installed-component-proof.json')
    publication = fixture.json(history + '-committed-component-receipts.json')
    readback = fixture.json(history + '-readback.json')
    expected = fixture.json(label + '-operation-expectations.json')
    digest = '9' * 64
    target = m.sha(fixture.data[history + '-committed-journal.json'] + fixture.data[history + '-committed-report.json']
                   + fixture.data[history + '-committed-component-receipts.json'] + fixture.data[history + '-committed-installed-component-proof.json']
                   + proof['im4pSHA256'].encode())
    proof.update(transactionID=m.RB_TX, imageSHA256=digest, operation='kernel-rollback', bindingSHA256=before['binding_sha256'],
                 liveDesiredSHA256=before['desired_sha256'], targetDesiredSHA256=expected['desiredSHA256'], targetTransactionID=m.B_TX, targetEvidenceSHA256=target)
    fixture.put(label + '-committed-installed-component-proof.json', proof)
    publication['transactionID'] = m.RB_TX
    publication['installed']['outputs'] = [{'path': 'Disk.img', 'sha256': digest}]
    publication['originProofSHA256'] = m.sha(fixture.data[label + '-committed-installed-component-proof.json'])
    fixture.put(label + '-committed-component-receipts.json', publication)
    fixture.data[label + '-committed-report.json'] = fixture.data[history + '-committed-report.json']
    journal.update(id=m.RB_TX, version=4)
    journal['kernelDisk'].update(originalSHA256=before['files']['Disk.img']['sha256'], candidateSHA256=digest)
    selection = fixture.json(m.ORIGIN + '-committed-journal.json')['rollbackSelection']
    selection.update(targetTransactionID=m.B_TX, targetEvidenceSHA256=target, targetDesired=before['desired'], targetPayloadSHA256=proof['payloadSHA256'],
                     targetIM4PSHA256=proof['im4pSHA256'], bindingSHA256=before['binding_sha256'], liveDesiredSHA256=before['desired_sha256'])
    journal['rollbackSelection'] = selection
    journal['componentReceiptsSHA256'] = m.sha(fixture.data[label + '-committed-component-receipts.json'])
    for entry in journal['metadata']:
        if entry['name'] == '.firmware-component-receipts.json': entry.update(original=before['receipt_sha256'], output=journal['componentReceiptsSHA256'])
        else: entry['original'] = before['binding_sha256']
    fixture.put(label + '-committed-journal.json', journal)
    readback.update(transaction_id=m.RB_TX, journal_version=4, proof=proof, receipt=publication['installed'], expected=expected,
                    expectations_sha256=m.sha(fixture.data[label + '-operation-expectations.json']), rollback_selection=selection, disk_sha256_after_readonly=digest)
    readback['files'] = {name: dict(sha256=digest if name == 'Disk.img' else old['sha256'], inode=old['metadata']['st_ino'],
                                   identity_unchanged=True, content_unchanged=name != 'Disk.img') for name, old in before['files'].items()}
    fixture.put(label + '-readback.json', readback)
    fixture.put(label + '.json', {'exit_code': 0, 'command': m.OFFLINE + [m.CLI9, 'vm', 'rollback-kernel', 'task8-copy', '--library-root', m.LIBRARY, '--to-transaction', m.B_TX]})
    # Formal host rebind/owner witnesses are also synthetic, never written to E.
    rebind = fixture.json(label + '-source9-host-rebind-check.json')
    rebind.update(target_version=m.V4, command=[m.CLI9, 'vm', 'bind-core-bundle', 'task8-copy', '--library-root', m.LIBRARY, '--version', m.V4])
    for value in (rebind['before'], rebind['after']):
        value.update(receipt_sha256=journal['componentReceiptsSHA256'], desired_sha256=m.DESIRED_B_SHA,
                     journal_sha256=m.sha(fixture.data[label + '-committed-journal.json']), proof_sha256=m.sha(fixture.data[label + '-committed-installed-component-proof.json']))
    rebind['before'].update(binding=readback['binding'], binding_sha256=next(x['output'] for x in journal['metadata'] if x['name'] == 'launchpad.json'))
    reboot_expected = fixture.json(m.REBOOT + '-boot-expectations.json')
    rebind['after'].update(binding=reboot_expected['binding'], binding_sha256=reboot_expected['binding_sha256'])
    fixture.put(label + '-host4-host-rebind-check.json', rebind)
    owner = fixture.json(label + '-source9-binding-owner-check.json')
    owner.update(rebind_label=label + '-host4', binding_sha256=reboot_expected['binding_sha256'])
    fixture.put(label + '-host4-binding-owner-check.json', owner)
    boot = fixture.json(m.REBOOT + '-boot-watch.json')
    new_target = dict(vm='task8-copy', pid=100001, instance_id='A5B39980-23D8-4B52-A79C-EE00B84157B6', process_started_at=boot['target']['process_started_at'] + 1000)
    boot_expected = dict(reboot_expected, transaction_id=m.RB_TX, payload_sha256=m.PAYLOAD_B, receipt_sha256=journal['componentReceiptsSHA256'])
    fixture.put(label + '-boot-expectations.json', boot_expected)
    boot.update(expected=boot_expected, expectations_sha256=m.sha(fixture.data[label + '-boot-expectations.json']), target=new_target)
    previous_read = fixture.json(m.REBOOT + '-marker-v2-read.json')
    cap = copy.deepcopy(previous_read['requests'][0]['response']); cap['target'] = new_target
    messages = [{'t': 'capabilities'}, {'t': 'shell', 'cmd': m.GUEST_STATE, 'timeout_ms': 10000, 'target': new_target}]
    boot['attempts'] = [dict(command=[m.CLI4, 'guest', 'send', 'task8-copy', '--library-root', m.LIBRARY, '--timeout', '15', json.dumps(message, separators=(',', ':'))],
                             exit_code=0, response=value, stdout=json.dumps(value), stderr='') for message, value in zip(messages, [cap, boot['guest_state']])]
    fixture.put(label + '-boot-watch.json', boot)
    restored = previous_read
    restored.update(boot_label=label, evidence_label=label, target=new_target, expected=boot_expected,
                    source_boot_evidence=str(E / (label + '-boot-watch.json')), source_boot_sha256=m.sha(fixture.data[label + '-boot-watch.json']))
    for event in restored['requests']:
        event['message']['target'] = new_target
        event['command'][-1] = json.dumps(event['message'], separators=(',', ':'))
        if event['message']['t'] == 'capabilities': event['response']['target'] = new_target
        event['stdout'] = json.dumps(event['response'])
    fixture.put(label + '-marker-v2-read.json', restored)
    for suffix in ('-vm-launch.json', '-vm-stop.json', '-post-boot-cleanup.json'):
        value = fixture.json(m.REBOOT + suffix)
        if suffix == '-post-boot-cleanup.json': value['label'] = label
        fixture.put(label + suffix, value)
    fixture.data[label + '-vm-stop.log'] = ('task8-copy: boot instance ' + new_target['instance_id'] + '\ntask8-copy: sending SIGINT to ' + str(new_target['pid']) + '\ntask8-copy: stopped\n').encode()
    fixture.data[label + '-vm-launch.log'] = fixture.data[m.REBOOT + '-vm-launch.log']
    return fixture


class DocumentsPersistenceTests(unittest.TestCase):
    def setUp(self):
        self.guards = [patch.object(subprocess, name, side_effect=AssertionError('Real subprocess forbidden')) for name in ('run', 'Popen', 'check_output')]
        self.guards += [patch.object(os, name, side_effect=AssertionError('Real signal forbidden')) for name in ('kill', 'killpg')]
        for guard in self.guards: guard.start()
    def tearDown(self):
        for guard in reversed(self.guards): guard.stop()
    def test_complete_memory_fixture_passes_only_new_scenario(self):
        result = m.verify(synthetic_complete())
        self.assertEqual(result.get('error'), None)
        self.assertTrue(result['passed']); self.assertEqual(result['status'], 'passed')
        self.assertTrue(result['old_tmp_failure_preserved']); self.assertTrue(result['same_kernel_reboot_verified']); self.assertTrue(result['cross_rollback_documents_verified'])
        self.assertEqual(result['marker_size'], 1254); self.assertEqual(result['marker_sha256'], m.MARKER_SHA)
    def test_missing_final_rollback_evidence_is_pending_not_passed(self):
        result = m.verify(saved_inputs())
        self.assertFalse(result['passed']); self.assertEqual(result['status'], 'pending', result.get('error'))
        self.assertTrue(result['same_kernel_reboot_verified']); self.assertTrue(result['old_tmp_failure_preserved']); self.assertTrue(result['missing'])
    def test_old_failed_tmp_record_cannot_be_promoted_or_changed(self):
        fixture = synthetic_complete(); name = m.ORIGIN + '-marker-read.json'; record = fixture.json(name); record['passed'] = True; fixture.put(name, record)
        result = m.verify(fixture); self.assertFalse(result['passed']); self.assertEqual(result['status'], 'refused')
    def test_original_create_and_intent_cannot_be_replaced(self):
        for kind in ('create', 'intent'):
            fixture = synthetic_complete(); name = m.CREATE + '-marker-v2-' + kind + '.json'
            record = fixture.json(name); record['unapproved_extra'] = True; fixture.put(name, record)
            with self.subTest(kind=kind): self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_read_cannot_create_or_sync_guest(self):
        fixture = synthetic_complete(); name = m.ROLLBACK + '-marker-v2-read.json'; record = fixture.json(name)
        record['requests'][1]['message'] = {'t': 'shell', 'cmd': 'echo replaced', 'target': record['target']}; fixture.put(name, record)
        self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_actual_file_get_bytes_are_checked_not_only_passed_sha(self):
        fixture = synthetic_complete(); name = m.ROLLBACK + '-marker-v2-read.json'; record = fixture.json(name)
        record['requests'][1]['response']['data'] = base64.b64encode(b'wrong bytes').decode(); record['requests'][1]['stdout'] = json.dumps(record['requests'][1]['response']); fixture.put(name, record)
        self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_wrong_created_record_provenance_is_rejected(self):
        fixture = synthetic_complete(); name = m.ROLLBACK + '-marker-v2-read.json'; record = fixture.json(name); record['created_record_sha256'] = '0' * 64; fixture.put(name, record)
        self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_same_instance_and_earlier_instance_are_rejected(self):
        for kind in ('same', 'earlier'):
            fixture = synthetic_complete(); name = m.ROLLBACK + '-boot-watch.json'; record = fixture.json(name)
            if kind == 'same': record['target']['instance_id'] = fixture.json(m.REBOOT + '-boot-watch.json')['target']['instance_id']
            else: record['target']['process_started_at'] = 1
            fixture.put(name, record)
            with self.subTest(kind=kind): self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_uncommitted_phase_or_wrong_public_uuid_rejected(self):
        for field, value in [('phase', 'publishing'), ('id', m.B_TX)]:
            fixture = synthetic_complete(); name = m.ROLLBACK + '-committed-journal.json'; record = fixture.json(name); record[field] = value; fixture.put(name, record)
            with self.subTest(field=field): self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_preview_recover_or_wrong_target_is_not_public_rollback(self):
        for option in ('--preview', '--recover', '--list'):
            fixture = synthetic_complete(); name = m.ROLLBACK + '.json'; record = fixture.json(name); record['command'].append(option); fixture.put(name, record)
            with self.subTest(option=option): self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_wrong_actual_payload_is_rejected(self):
        fixture = synthetic_complete(); name = m.ROLLBACK + '-readback.json'; record = fixture.json(name); record['kernel']['payload_sha256'] = m.PAYLOAD_A; fixture.put(name, record)
        self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_live_desired_binding_cas_and_receipt_digest_are_checked(self):
        for field in ('liveDesiredSHA256', 'bindingSHA256'):
            fixture = synthetic_complete(); name = m.ROLLBACK + '-committed-installed-component-proof.json'; record = fixture.json(name); record[field] = '0' * 64; fixture.put(name, record)
            with self.subTest(field=field): self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_boot_guest_outer_failure_timeout_and_truncation_rejected(self):
        for kind in ('outer', 'timeout', 'truncated'):
            fixture = synthetic_complete(); name = m.ROLLBACK + '-boot-watch.json'; record = fixture.json(name)
            if kind == 'outer': record['attempts'][-1]['exit_code'] = 1
            else: record['guest_state']['timed_out' if kind == 'timeout' else 'truncated'] = True
            fixture.put(name, record)
            with self.subTest(kind=kind): self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_stop_wrong_instance_or_cleanup_pending_is_rejected(self):
        fixture = synthetic_complete(); fixture.data[m.ROLLBACK + '-vm-stop.log'] = b'task8-copy: stopped\n'
        self.assertEqual(m.verify(fixture)['status'], 'refused')
        fixture = synthetic_complete(); name = m.ROLLBACK + '-post-boot-cleanup.json'; record = fixture.json(name); record['desired_pending'] = True; fixture.put(name, record)
        self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_host_rebind_cannot_change_receipt_or_kernel(self):
        fixture = synthetic_complete(); name = m.ROLLBACK + '-host4-host-rebind-check.json'; record = fixture.json(name); record['after']['receipt_sha256'] = '0' * 64; fixture.put(name, record)
        self.assertEqual(m.verify(fixture)['status'], 'refused')
    def test_saved_input_identity_change_refuses_final_result(self):
        fixture = synthetic_complete(); fixture.changed = 'clone.json'; result = m.verify(fixture)
        self.assertFalse(result['passed']); self.assertEqual(result['status'], 'refused'); self.assertIn('input_stability_error', result)
    def test_strict_json_duplicate_nan_and_path_traversal_rejected(self):
        for value in ('{"a":1,"a":2}', '{"a":NaN}'):
            with self.assertRaises(ValueError): m.decode(value)
        for name in ('../secret', '/private/tmp/Disk.img', 'a/../x', 'other/file.json'):
            with self.assertRaises(ValueError): m.valid_name(name)
    def test_file_evidence_ordinary_only_and_exclusive_output(self):
        with tempfile.TemporaryDirectory(prefix='documents-evidence-pure-') as name:
            root = Path(name); ordinary = root / 'ordinary.json'; ordinary.write_bytes(b'{"passed":true}')
            reader = m.FileEvidence(root); snapshot = reader.read('ordinary.json'); self.assertEqual(snapshot.data, ordinary.read_bytes())
            (root / 'linked.json').symlink_to(ordinary)
            with self.assertRaises(OSError): reader.read('linked.json')
            os.link(ordinary, root / 'hard.json')
            with self.assertRaises(ValueError): reader.read('ordinary.json')
            with self.assertRaises(FileExistsError): m.reserve_output(ordinary)
            self.assertEqual(ordinary.read_bytes(), b'{"passed":true}')


if __name__ == '__main__': unittest.main(verbosity=2)

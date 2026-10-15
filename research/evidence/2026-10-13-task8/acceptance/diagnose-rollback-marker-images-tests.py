"""Pure functions/ordinary-file tests. No VM, hdiutil, mount or process API."""
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('marker_images', E / 'diagnose-rollback-marker-images.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
RELATIVE = 'tmp/task8-kernel-rollback-' + m.OLD_UUID
VOLUME_UUID = 'E5171CB9-E60B-4E98-B997-14E45225ABF6'


class FakeOperations:
    """Command responses are literals; fake mount creates only ordinary files."""
    def __init__(self, marker=None, attach_fails=False, writable=False, detach_fails=False, encrypted=False, preexisting=False, mutate=False):
        self.record = {'images': [], 'commands': []}; self.marker = marker
        self.attach_fails, self.writable, self.detach_fails = attach_fails, writable, detach_fails
        self.encrypted, self.active, self.preexisting, self.mutate = encrypted, preexisting, preexisting, mutate
        self.mount = None; self.image = None
    def guard(self): m.require(not self.preexisting, 'Existing attachment')
    def attachments(self, image):
        return [{'image-path': str(image), 'system-entities': [{'content-hint': 'GUID_partition_scheme', 'dev-entry': '/dev/disk77'}]}] if self.active else []
    def task8_attachments(self): return self.attachments(self.image) if self.active else []
    def run(self, command):
        self.record['commands'].append(command)
        if command[1] == 'attach':
            self.image = Path(command[-1]); self.active = True
            if self.attach_fails: raise RuntimeError('Injected attach failure after attachment')
            return plistlib.dumps(self.attachments(self.image)[0])
        if command[1:3] == ['apfs', 'list']:
            return plistlib.dumps({'Containers': [{'ContainerReference': 'disk88', 'PhysicalStores': [{'DeviceIdentifier': 'disk77s1'}],
                'Volumes': [{'DeviceIdentifier': 'disk88s2', 'Name': 'Data', 'APFSVolumeUUID': VOLUME_UUID, 'Roles': ['Data'], 'Encrypted': self.encrypted}]}]})
        if command[0] == '/sbin/mount_apfs':
            self.mount = Path(command[-1])
            if self.marker is not None:
                directory = self.mount / 'tmp'; directory.mkdir(); (directory / Path(RELATIVE).name).write_bytes(self.marker)
            return b''
        if command[1:3] == ['info', '-plist']:
            return plistlib.dumps({'DeviceIdentifier': 'disk88s2', 'VolumeName': 'Data', 'VolumeUUID': VOLUME_UUID,
                'WritableVolume': self.writable, 'MountPoint': str(self.mount), 'APFSPhysicalStores': [{'APFSPhysicalStore': 'disk77s1'}]})
        if command[1] == 'detach':
            if self.detach_fails: raise RuntimeError('Injected detach failure')
            self.active = False
            if self.mutate: self.image.write_bytes(b'altered')
            # Simulate unmount exposing the empty underlying mount directory.
            if self.mount is not None:
                directory = self.mount / 'tmp'
                if directory.exists():
                    for item in directory.iterdir(): item.unlink()
                    directory.rmdir()
            return b''
        raise AssertionError('Unexpected fake command: ' + repr(command))


def synthetic_v2():
    target = {'vm': 'task8-copy', 'pid': 79393, 'instance_id': 'F8D80AB2-808A-49BB-A73E-E231D876AC96', 'process_started_at': 1791969000.5}
    expected = {'transaction_id': m.TX, 'binding': {'bundle': '2.6.20261016-local', 'kernel': '2.6.20261021-local'},
                'binding_sha256': '1' * 64, 'receipt_sha256': '2' * 64, 'desired_sha256': '3' * 64, 'payload_sha256': '4' * 64}
    identity = {'vm_directory': str(m.VM), 'machine_identifier_sha256': '5' * 64, 'generation_id': '6' * 64, 'config_sha256': '7' * 64}
    token = 'D57F7E5B-4B51-45F9-99C7-E624DE72E390'.lower()
    marker = {'uuid': token, 'path': '/private/var/mobile/Documents/task8-kernel-rollback-' + token,
              'target': target, 'expected': expected, 'source_boot_label': 'pure-boot', 'created_evidence_label': 'pure-create', 'vm_identity': identity}
    canonical = {'schemaVersion': 2, 'protocol': 'task8.guest-marker.v2', 'purpose': 'Task8 committed kernel rollback persistent guest marker',
                 'uuid': token, 'created_by_instance': target, 'installed_expectations': expected, 'source_boot_label': 'pure-boot',
                 'created_evidence_label': 'pure-create', 'vm_identity': identity}
    content = (json.dumps(canonical, sort_keys=True, separators=(',', ':')) + '\n').encode()
    marker.update(content_base64=base64.b64encode(content).decode(), content_sha256=m.sha(content), size=len(content))
    shell = {'ok': True, 'code': 0, 'timed_out': False, 'truncated': False, 'stdout': '', 'stderr': ''}
    capabilities = {'ok': True, 'target': target, 'boot_mode': 'normal', 'guest_connected': True, 'commands': {'shell': True, 'file_get': True}}
    messages = [{'t': 'capabilities', 'target': target},
                {'t': 'shell', 'cmd': m.SYNC_PROBE, 'timeout_ms': 10000, 'target': target},
                {'t': 'shell', 'cmd': '(set -C && printf %s ' + shlex.quote(content.decode()) + ' > ' + shlex.quote(marker['path']) + ')', 'timeout_ms': 10000, 'target': target},
                {'t': 'shell', 'cmd': 'exec /bin/sync', 'timeout_ms': 60000, 'target': target},
                {'t': 'file_get', 'path': marker['path'], 'target': target}, {'t': 'capabilities', 'target': target}]
    responses = [capabilities, dict(shell, stdout='/bin/sync\n'), shell, shell, {'ok': True, 'data': marker['content_base64'], 'size': len(content)}, capabilities]
    events = [{'message': message, 'command': [m.CLI4, 'guest', 'send', 'task8-copy', '--library-root', str(m.TASK_ROOT), '--timeout', '75', json.dumps(message)],
               'response': response, 'stdout': json.dumps(response), 'exit_code': 0, 'host_timed_out': False} for message, response in zip(messages, responses)]
    return {'schemaVersion': 2, 'protocol': 'task8.guest-marker.v2', 'passed': True, 'mode': 'create', 'boot_label': 'pure-boot',
            'evidence_label': 'pure-create', 'target': target, 'expected': expected, 'vm_identity': identity, 'requests': events, 'marker': marker,
            'downloaded_sha256': m.sha(content), 'downloaded_size': len(content), 'sync': {'request_index': 3, 'executable': '/bin/sync', 'response': shell}}


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='task8-marker-pure-test-')
        self.root = Path(self.temp.name)
        self.external = patch.object(subprocess, 'run', side_effect=AssertionError('Real external operation forbidden'))
        self.external.start()
    def tearDown(self): self.external.stop(); self.temp.cleanup()
    def image(self):
        path = self.root / 'ordinary.img'; path.write_bytes(b'ordinary fixture'); return path
    def inspect(self, operations, **kwargs):
        image = self.image()
        return m.inspect_image(operations, image, 'Data', RELATIVE, b'marker', m.sha(image.read_bytes()), image.stat().st_size, **kwargs)
    def test_frozen_old_marker_record_validates_actual_file_get(self):
        record = m.decode_json((E / 'kernel-v9-plan-b-resumed-marker-create.json').read_bytes())
        intent = m.decode_json((E / 'kernel-v9-plan-b-resumed-marker-intent.json').read_bytes())
        marker, data = m.validate_marker(record, intent)
        self.assertEqual(len(data), 742); self.assertEqual(m.sha(data), m.OLD_SHA)
        self.assertEqual(marker['path'].rsplit('/', 1)[-1], Path(RELATIVE).name)
    def test_old_record_changed_file_get_is_rejected(self):
        record = m.decode_json((E / 'kernel-v9-plan-b-resumed-marker-create.json').read_bytes())
        intent = m.decode_json((E / 'kernel-v9-plan-b-resumed-marker-intent.json').read_bytes())
        record['requests'][2]['response']['data'] = base64.b64encode(b'wrong').decode()
        record['requests'][2]['stdout'] = json.dumps(record['requests'][2]['response'])
        with self.assertRaises(RuntimeError): m.validate_marker(record, intent)
    def test_v2_documents_create_sync_and_file_get_validate(self):
        record = synthetic_v2(); marker, content = m.validate_marker(record, record['marker'], documents=True)
        self.assertTrue(marker['path'].startswith('/private/var/mobile/Documents/')); self.assertEqual(m.sha(content), record['downloaded_sha256'])
    def test_v2_sync_timeout_wrong_path_and_changed_bytes_rejected(self):
        for change in ('sync_timeout', 'wrong_path', 'changed_bytes', 'unknown_probe', 'host_timeout'):
            record = synthetic_v2()
            if change == 'sync_timeout':
                record['requests'][3]['response']['timed_out'] = True
                record['requests'][3]['stdout'] = json.dumps(record['requests'][3]['response'])
            elif change == 'wrong_path': record['marker']['path'] = '/private/var/tmp/' + Path(record['marker']['path']).name
            elif change == 'changed_bytes':
                record['requests'][4]['response']['data'] = base64.b64encode(b'wrong').decode()
                record['requests'][4]['stdout'] = json.dumps(record['requests'][4]['response'])
            elif change == 'unknown_probe':
                record['requests'][1]['message']['cmd'] = 'unknown'
                record['requests'][1]['command'][8] = json.dumps(record['requests'][1]['message'])
            else: record['requests'][0]['host_timed_out'] = True
            with self.subTest(change=change), self.assertRaises(RuntimeError): m.validate_marker(record, record['marker'], documents=True)
    def test_current_documents_actual_file_bytes(self):
        record = synthetic_v2(); marker, content = m.validate_marker(record, record['marker'], documents=True)
        (self.root / 'Documents').mkdir(); (self.root / 'Documents' / Path(marker['path']).name).write_bytes(content)
        result = m.read_marker(self.root, 'Documents/' + Path(marker['path']).name, content)
        self.assertTrue(result['exists']); self.assertTrue(result['content_matches']); self.assertEqual(result['sha256'], record['downloaded_sha256'])
    def test_optional_config_binary_and_xml_plist_use_raw_frozen_loader(self):
        for kind in (plistlib.FMT_BINARY, plistlib.FMT_XML):
            config = self.root / ('config-' + str(kind) + '.plist')
            raw = plistlib.dumps({'machineIdentifier': b'ordinary-test-machine'}, fmt=kind); config.write_bytes(raw)
            frozen, digests = {}, {}
            actual = m.load_frozen(config, frozen, digests, raw=True)
            self.assertEqual(actual, raw); self.assertEqual(plistlib.loads(actual)['machineIdentifier'], b'ordinary-test-machine')
            self.assertEqual(digests[str(config)], m.sha(raw)); self.assertEqual(m.observe_file(config, 16 << 20), frozen[config])
            # JSON inputs retain strict JSON parsing and the same freeze/recheck.
            with self.assertRaises((ValueError, UnicodeError)): m.load_frozen(config, {}, {})
    def test_exclusive_output_preserves_previous_file(self):
        path = self.root / 'out.json'; path.write_bytes(b'old')
        with self.assertRaises(FileExistsError): m.exclusive_output(path)
        self.assertEqual(path.read_bytes(), b'old')
    def test_duplicate_json_and_nan_are_rejected(self):
        for text in ('{"a":1,"a":2}', '{"a":NaN}'):
            with self.assertRaises(RuntimeError): m.decode_json(text)
    def test_ordinary_full_sha_and_identity(self):
        path = self.image(); result, unused = m.observe_file(path)
        self.assertEqual(result['sha256'], m.sha(path.read_bytes())); self.assertEqual(unused, b'')
        self.assertEqual(result['metadata']['st_ino'], path.stat().st_ino)
    def test_symlink_and_hardlink_evidence_rejected(self):
        path = self.image(); symlink = self.root / 'link'; symlink.symlink_to(path)
        with self.assertRaises(OSError): m.observe_file(symlink)
        os.link(path, self.root / 'hardlink')
        with self.assertRaises(RuntimeError): m.observe_file(path)
    def test_missing_marker_is_an_observation(self):
        result = m.read_marker(self.root, RELATIVE, b'marker')
        self.assertFalse(result['exists']); self.assertEqual(result['missing_component'], 'tmp')
        (self.root / 'tmp').mkdir(); result = m.read_marker(self.root, RELATIVE, b'marker')
        self.assertFalse(result['exists'])
    def test_actual_marker_bytes_and_mismatch_are_recorded(self):
        (self.root / 'tmp').mkdir(); path = self.root / RELATIVE; path.write_bytes(b'marker')
        self.assertTrue(m.read_marker(self.root, RELATIVE, b'marker')['content_matches'])
        result = m.read_marker(self.root, RELATIVE, b'other'); self.assertTrue(result['exists']); self.assertFalse(result['content_matches'])
    def test_marker_symlink_and_hardlink_rejected(self):
        (self.root / 'tmp').mkdir(); path = self.root / RELATIVE; ordinary = self.root / 'ordinary'; ordinary.write_bytes(b'marker')
        path.symlink_to(ordinary)
        with self.assertRaises(OSError): m.read_marker(self.root, RELATIVE, b'marker')
        path.unlink(); os.link(ordinary, path)
        with self.assertRaises(RuntimeError): m.read_marker(self.root, RELATIVE, b'marker')
    def test_marker_directory_symlink_and_traversal_rejected(self):
        (self.root / 'tmp').symlink_to(self.root)
        with self.assertRaises(OSError): m.read_marker(self.root, RELATIVE, b'marker')
        for path in ('../' + Path(RELATIVE).name, 'tmp/../' + Path(RELATIVE).name, 'tmp/task8-kernel-rollback-INVALID'):
            with self.assertRaises(RuntimeError): m.read_marker(self.root, path, b'marker')
    def test_wrong_physical_store_and_ambiguous_volume_rejected(self):
        container = {'PhysicalStores': [{'DeviceIdentifier': 'disk77s1'}], 'Volumes': [{'Name': 'Data', 'DeviceIdentifier': 'disk88s2', 'APFSVolumeUUID': VOLUME_UUID}]}
        self.assertEqual(m.choose_volume([container], '/dev/disk77', 'Data')[1]['Name'], 'Data')
        for bad in ([dict(container, PhysicalStores=[{'DeviceIdentifier': 'disk66s1'}])], [container, container],
                    [dict(container, Volumes=container['Volumes'] * 2)], [dict(container, PhysicalStores=container['PhysicalStores'] * 2)]):
            with self.assertRaises(RuntimeError): m.choose_volume(bad, '/dev/disk77', 'Data')
    def test_missing_archive_marker_passes_with_detach_and_full_rehash(self):
        operations = FakeOperations(); result = self.inspect(operations)
        self.assertTrue(result['passed']); self.assertFalse(result['marker']['exists']); self.assertFalse(operations.active)
        self.assertEqual(result['before'], result['after']); self.assertEqual(result['remaining_task8_attachments'], [])
    def test_present_exact_marker_passes(self):
        self.assertTrue(self.inspect(FakeOperations(marker=b'marker'))['marker']['content_matches'])
    def test_optional_current_missing_marker_fails_with_cleanup(self):
        operations = FakeOperations()
        with self.assertRaises(RuntimeError): self.inspect(operations, require_exists=True)
        self.assertFalse(operations.active); self.assertFalse(operations.record['images'][0]['passed'])
    def test_mismatched_marker_fails_but_retains_bytes_and_detaches(self):
        operations = FakeOperations(marker=b'other')
        with self.assertRaises(RuntimeError): self.inspect(operations)
        result = operations.record['images'][0]; self.assertFalse(result['marker']['content_matches']); self.assertFalse(operations.active)
        self.assertEqual(base64.b64decode(result['marker']['content_base64']), b'other')
    def test_partial_attach_failure_detaches_owned_attachment(self):
        operations = FakeOperations(attach_fails=True)
        with self.assertRaises(RuntimeError): self.inspect(operations)
        self.assertFalse(operations.active); self.assertTrue(any(command[1] == 'detach' for command in operations.record['commands']))
    def test_preexisting_attachment_is_not_detached(self):
        operations = FakeOperations(preexisting=True)
        with self.assertRaises(RuntimeError): self.inspect(operations)
        self.assertTrue(operations.active); self.assertFalse(any(command[1] == 'detach' for command in operations.record['commands']))
    def test_encrypted_and_writable_fail_without_success(self):
        for settings in ({'encrypted': True}, {'encrypted': 'Unknown'}, {'writable': True}):
            operations = FakeOperations(**settings)
            with self.assertRaises(RuntimeError): self.inspect(operations)
            self.assertFalse(operations.active); self.assertFalse(operations.record['images'][0]['passed'])
            self.assertIn('apfs_containers', operations.record['images'][0])
    def test_detach_failure_is_not_passed(self):
        operations = FakeOperations(detach_fails=True)
        try:
            with self.assertRaises(RuntimeError): self.inspect(operations)
            self.assertTrue(operations.active); self.assertFalse(operations.record['images'][0]['passed'])
            self.assertIn('cleanup_errors', operations.record['images'][0])
        finally:
            # Ordinary test directories only, never a mounted path.
            if operations.mount is not None: operations.mount.rmdir(); operations.mount.parent.rmdir()
    def test_changed_image_after_detach_fails_full_rehash(self):
        operations = FakeOperations(mutate=True)
        with self.assertRaises(RuntimeError): self.inspect(operations)
        result = operations.record['images'][0]; self.assertNotEqual(result['before']['sha256'], result['after']['sha256'])
        self.assertFalse(result['passed']); self.assertFalse(operations.active)


if __name__ == '__main__': unittest.main(verbosity=2)

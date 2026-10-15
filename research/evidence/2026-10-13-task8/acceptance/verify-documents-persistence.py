"""Join saved Task8 Documents persistence evidence. Never contact a VM or Store.

This independent scenario retains the failed historical tmp-marker observation.
Missing final rollback/boot evidence is pending, never an acceptance pass.
"""
import argparse
import base64
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import sys
import uuid

E = Path(__file__).resolve().parent
VM = '/private/tmp/vphone-task8-acceptance-vms/task8-copy'
LIBRARY = '/private/tmp/vphone-task8-acceptance-vms'
V4 = '2.6.20261016-local'
V9 = '2.6.20261021-local'
CLI4 = '/Library/Application Support/vphone-launchpad/Bundles/' + V4 + '/VPhone.bundle/Contents/MacOS/vphone-cli'
CLI9 = '/Library/Application Support/vphone-launchpad/Bundles/' + V9 + '/VPhone.bundle/Contents/MacOS/vphone-cli'
VM4 = '/Library/Application Support/vphone-launchpad/Bundles/' + V4 + '/VPhone.bundle/Contents/MacOS/vphone-vm'
OFFLINE = ['sudo', '-n', 'env', 'PYTHONDONTWRITEBYTECODE=1', 'VPHONE_PYTHON=/Users/qcz3840/github/vphone-cli/.venv/bin/python3']
ORIGIN = 'kernel-v9-rollback-a'
CREATE = ORIGIN + '-persistent'
REBOOT = 'kernel-v9-documents-reboot-a'
ROLLBACK = 'kernel-v9-documents-rollback-b'
HISTORY = 'kernel-v9-plan-b'
A_TX = '58597f0a-e94c-4f69-86af-b0fdfa9fd3f3'
B_TX = '2901d975-2379-4b50-9340-8580786aacc1'
RB_TX = '0d6d197a-8b24-4944-bb38-16a60ed24fb0'
CLI_SHA = 'e1c6ca75c19966ec8bcada05ca235c1e5019c572570b64e8ebed041f0d14da76'
OLD_FAILURE_SHA = 'af26e5130253333e99034296d5e31c055bf4e13d0d2e43a56222f447fcc05835'
CREATE_SHA = '2f8a003bfc48b3f0dd64beaafb5ee679a6208304a7669530336cead0358c61d0'
MARKER_SHA = 'a8faa4e5b805fd5a0ee0f8330296d168bb85f33c674748595d176df3714e418e'
DESIRED_B_SHA = '3ad404b6361d1989bda18be961ce72d1415f6e84025138ec6623bc0578aad949'
PAYLOAD_A = 'd2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb'
PAYLOAD_B = 'a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0'
FILES = {'Disk.img', 'nvram.bin', 'SEPStorage', 'config.plist', 'AVPBooter.vresearch1.bin', 'AVPSEPBooter.vresearch1.bin'}
SYNC_PROBE = "if [ -x /bin/sync ]; then printf '%s\\n' /bin/sync; elif [ -x /var/jb/usr/bin/sync ]; then printf '%s\\n' /var/jb/usr/bin/sync; else exit 69; fi"
GUEST_STATE = '/var/jb/usr/bin/uname -a; /var/jb/usr/sbin/sysctl kern.osrelease hw.machine'


class Pending(Exception): pass


def require(value, message):
    if not value: raise ValueError(message)


def sha(data): return hashlib.sha256(data).hexdigest()


def decode(data):
    def pairs(items):
        value = {}
        for key, item in items:
            require(key not in value, 'Duplicate JSON field: ' + key); value[key] = item
        return value
    def invalid(value): raise ValueError('Non-finite JSON value: ' + value)
    value = json.loads(data, object_pairs_hook=pairs, parse_constant=invalid)
    require(isinstance(value, dict), 'Expected JSON object')
    return value


def canonical_uuid(value):
    require(isinstance(value, str) and str(uuid.UUID(value)) == value, 'Expected canonical transaction UUID')


def valid_name(name):
    require(isinstance(name, str) and len(name) <= 180 and re.fullmatch(r'[a-z0-9][a-z0-9./_-]*', name), 'Invalid evidence name')
    parts = PurePosixPath(name).parts
    require(parts and not name.startswith('/') and all(part not in ('.', '..') for part in parts), 'Evidence path escapes root')
    require(len(parts) == 1 or len(parts) == 2 and parts[0] == 'kernel-rollback', 'Unexpected evidence subdirectory')
    return parts


@dataclass(frozen=True)
class Snapshot:
    data: bytes
    identity: tuple


class FileEvidence:
    """Only ordinary saved files below one fixed evidence directory."""
    def __init__(self, base=E): self.base = Path(base)
    def read(self, name):
        parts = valid_name(name)
        directory = os.open(self.base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        descriptors = [directory]
        try:
            for part in parts[:-1]:
                directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
                descriptors.append(directory)
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
            descriptors.append(fd); before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 < before.st_size <= 16 << 20, 'Invalid saved evidence file')
            keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_nlink')
            def identity(info): return tuple(getattr(info, key) for key in keys)
            chunks, size = [], 0
            while True:
                chunk = os.read(fd, 1 << 20)
                if not chunk: break
                chunks.append(chunk); size += len(chunk); require(size <= 16 << 20, 'Evidence grew beyond limit')
            require(size == before.st_size and identity(before) == identity(os.fstat(fd))
                    == identity(os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)), 'Evidence changed during read')
            return Snapshot(b''.join(chunks), identity(before))
        finally:
            for fd in reversed(descriptors): os.close(fd)


class FrozenInputs:
    def __init__(self, evidence): self.evidence, self.snapshots = evidence, {}
    def raw(self, name):
        valid_name(name)
        if name not in self.snapshots: self.snapshots[name] = self.evidence.read(name)
        return self.snapshots[name].data
    def json(self, name): return decode(self.raw(name))
    def digest(self, name): return sha(self.raw(name))
    def recheck(self):
        for name, snapshot in self.snapshots.items():
            require(self.evidence.read(name) == snapshot, 'Saved input changed: ' + name)
    def hashes(self): return {name: sha(snapshot.data) for name, snapshot in self.snapshots.items()}


def target_valid(target):
    require(isinstance(target, dict) and set(target) == {'vm', 'pid', 'instance_id', 'process_started_at'}
            and target['vm'] == 'task8-copy' and type(target['pid']) is int and target['pid'] > 0, 'Wrong VM instance target')
    require(isinstance(target['instance_id'], str) and str(uuid.UUID(target['instance_id'])).upper() == target['instance_id'].upper(), 'Invalid instance UUID')
    require(type(target['process_started_at']) in (int, float) and math.isfinite(target['process_started_at'])
            and target['process_started_at'] > 0, 'Invalid process start time')


def expected_valid(expected):
    require(expected.get('binding') == {'bundle': V4, 'kernel': V9}, 'Expected frozen V4 host/V9 kernel binding')
    for key in ('binding_sha256', 'receipt_sha256', 'desired_sha256', 'payload_sha256'):
        require(isinstance(expected.get(key), str) and re.fullmatch(r'[0-9a-f]{64}', expected[key]), 'Invalid expected digest: ' + key)
    canonical_uuid(expected.get('transaction_id'))
    require(expected['desired_sha256'] == DESIRED_B_SHA, 'Live desired B was not retained')


def response(event, message, timeout='75'):
    require(event.get('command') == [CLI4, 'guest', 'send', 'task8-copy', '--library-root', LIBRARY, '--timeout', timeout,
                                     json.dumps(message, separators=(',', ':'))], 'Guest command/instance differs')
    require(type(event.get('exit_code')) is int and event['exit_code'] == 0
            and not event.get('client_timeout', False) and event.get('host_timed_out', False) is False, 'Guest client failed or timed out')
    raw = decode(event.get('stdout', '')); require(raw == event.get('response') and raw.get('ok') is True, 'Response/stdout mismatch or guest error')
    return raw


def shell_valid(value):
    require(value.get('ok') is True and type(value.get('code')) is int and value['code'] == 0
            and value.get('timed_out') is False and value.get('truncated') is False
            and isinstance(value.get('stdout'), str) and isinstance(value.get('stderr'), str), 'Shell result failed/timeout/truncated')


def capabilities_valid(value, target):
    require(value.get('target') == target and value.get('boot_mode') == 'normal' and value.get('guest_connected') is True
            and value.get('commands', {}).get('shell') is True and value.get('commands', {}).get('file_get') is True, 'Capabilities/instance differs')


def marker_canonical(marker):
    value = {'schemaVersion': 2, 'protocol': 'task8.guest-marker.v2', 'purpose': 'Task8 committed kernel rollback persistent guest marker',
             'uuid': marker['uuid'], 'created_by_instance': marker['target'], 'installed_expectations': marker['expected'],
             'source_boot_label': marker['source_boot_label'], 'created_evidence_label': marker['created_evidence_label'], 'vm_identity': marker['vm_identity']}
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def validate_create(inputs):
    name = CREATE + '-marker-v2-create.json'; record = inputs.json(name)
    require(inputs.digest(name) == CREATE_SHA, 'Fixed original Documents create evidence changed')
    require(record.get('schemaVersion') == 2 and record.get('protocol') == 'task8.guest-marker.v2' and record.get('passed') is True
            and record.get('mode') == 'create' and record.get('boot_label') == ORIGIN and record.get('evidence_label') == CREATE, 'Wrong original create provenance')
    target_valid(record['target']); expected_valid(record['expected'])
    require(record['expected']['transaction_id'] == A_TX and record['expected']['payload_sha256'] == PAYLOAD_A, 'Original marker is not from committed A')
    marker = record['marker']; token = marker['uuid']; canonical_uuid(token); require(uuid.UUID(token).version == 4, 'Marker UUID must be v4')
    require(marker['path'] == '/private/var/mobile/Documents/task8-kernel-rollback-' + token
            and marker['target'] == record['target'] and marker['expected'] == record['expected']
            and marker['source_boot_label'] == ORIGIN and marker['created_evidence_label'] == CREATE
            and marker['vm_identity'] == record['vm_identity'] and marker['vm_identity']['vm_directory'] == VM, 'Original marker identity/path differs')
    require(inputs.json(CREATE + '-marker-v2-intent.json') == marker, 'Original intent differs')
    content = base64.b64decode(marker['content_base64'], validate=True)
    require(content == marker_canonical(marker) and len(content) == record.get('downloaded_size') == marker.get('size') == 1254
            and sha(content) == marker.get('content_sha256') == record.get('downloaded_sha256') == MARKER_SHA, 'Original marker content/actual download differs')
    sync = record['sync']; require(sync.get('executable') in ('/bin/sync', '/var/jb/usr/bin/sync') and sync.get('request_index') == 3, 'Original explicit sync missing')
    messages = [
        {'t': 'capabilities', 'target': record['target']},
        {'t': 'shell', 'cmd': SYNC_PROBE, 'timeout_ms': 10000, 'target': record['target']},
        {'t': 'shell', 'cmd': '(set -C && printf %s ' + shlex.quote(content.decode()) + ' > ' + shlex.quote(marker['path']) + ')', 'timeout_ms': 10000, 'target': record['target']},
        {'t': 'shell', 'cmd': 'exec ' + sync['executable'], 'timeout_ms': 60000, 'target': record['target']},
        {'t': 'file_get', 'path': marker['path'], 'target': record['target']},
        {'t': 'capabilities', 'target': record['target']}]
    require(len(record['requests']) == 6, 'Original create request count differs')
    values = []
    for event, message in zip(record['requests'], messages):
        require(event.get('message') == message and event.get('host_timed_out') is False, 'Original create message differs')
        values.append(response(event, message))
    for index in (1, 2, 3): shell_valid(values[index])
    require(values[1]['stdout'] == sync['executable'] + '\n' and values[3] == sync['response'], 'Original sync discovery/result differs')
    for index in (0, 5): capabilities_valid(values[index], record['target'])
    require(type(values[4].get('size')) is int and values[4]['size'] == len(content)
            and base64.b64decode(values[4].get('data', ''), validate=True) == content, 'Original file_get bytes differ')
    return record, content


def validate_boot(inputs, label, publication, commit):
    expected_name = label + '-boot-expectations.json'; expected = inputs.json(expected_name)
    boot_name = label + '-boot-watch.json'; boot = inputs.json(boot_name)
    expected_valid(expected); target_valid(boot['target'])
    require(boot.get('passed') is True and boot.get('expected') == expected
            and boot.get('expectations_sha256') == inputs.digest(expected_name), 'Boot/expectations differs')
    require(expected['transaction_id'] == commit['transaction_id'] and expected['payload_sha256'] == commit['kernel']['payload_sha256']
            and expected['receipt_sha256'] == inputs.digest(publication)
            and expected['binding'] == dict(commit['binding'], bundle=V4), 'Boot is not bound to committed kernel/receipt')
    actual = boot.get('actual_vm_command', '')
    require(actual.startswith(VM4 + ' '), 'Actual VM executable differs')
    argv = shlex.split(actual[len(VM4) + 1:])
    require(argv.count('--config') == argv.count('--binding-sha256') == 1
            and argv[argv.index('--config') + 1] == VM + '/config.plist'
            and argv[argv.index('--binding-sha256') + 1] == expected['binding_sha256']
            and '--no-vphoned-update' in argv and '--no-vphoned' not in argv, 'Actual VM args/binding differs')
    state = boot.get('guest_state'); require(isinstance(state, dict), 'Guest state missing'); shell_valid(state)
    require(all(token in state['stdout'] for token in ('Darwin', 'kern.osrelease: 25.1.0', 'hw.machine: iPhone17,3')), 'Guest state markers differ')
    ready, final_shell = False, None
    attempts = boot.get('attempts'); require(isinstance(attempts, list) and attempts, 'Actual boot attempts missing')
    for event in attempts:
        command = event.get('command', [])
        if len(command) != 9 or event.get('exit_code') != 0 or not isinstance(event.get('response'), dict) or event['response'].get('ok') is not True: continue
        message = decode(command[8])
        if message == {'t': 'capabilities'}:
            value = response(event, message, '15')
            require(value.get('target') == boot['target'], 'Boot capability instance changed')
            if value.get('guest_connected') is True and value.get('commands', {}).get('shell') is True:
                capabilities_valid(value, boot['target']); ready = True
        elif message.get('t') == 'shell':
            require(ready and message == {'t': 'shell', 'cmd': GUEST_STATE, 'timeout_ms': 10000, 'target': boot['target']}, 'Boot shell target/sequence differs')
            value = response(event, message, '15')
            if value == state: shell_valid(value); final_shell = event
    require(ready and final_shell is not None, 'Successful guest state has no actual command evidence')
    return boot


def validate_read(inputs, label, created, content, boot):
    record = inputs.json(label + '-marker-v2-read.json')
    require(record.get('schemaVersion') == 2 and record.get('protocol') == 'task8.guest-marker.v2'
            and record.get('passed') is True and record.get('mode') == 'read'
            and record.get('boot_label') == record.get('evidence_label') == label, 'Successful readonly V2 read required')
    require(record.get('target') == boot['target'] and record.get('expected') == boot['expected']
            and record.get('source_boot_evidence') == str(E / (label + '-boot-watch.json'))
            and record.get('source_boot_sha256') == inputs.digest(label + '-boot-watch.json'), 'Read/current boot provenance differs')
    require(record.get('created_record') == str(E / (CREATE + '-marker-v2-create.json'))
            and record.get('created_record_sha256') == inputs.digest(CREATE + '-marker-v2-create.json')
            and record.get('marker') == created['marker'] and record.get('vm_identity') == created['vm_identity'], 'Read does not reference original create/VM identity')
    target_valid(record['target'])
    require(record['target']['instance_id'].upper() != created['target']['instance_id'].upper()
            and record['target']['process_started_at'] > created['target']['process_started_at'], 'Read requires a newer instance')
    require(type(record.get('downloaded_size')) is int and record['downloaded_size'] == len(content)
            and record.get('downloaded_sha256') == sha(content), 'Actual read size/SHA differs')
    messages = [{'t': 'capabilities', 'target': record['target']},
                {'t': 'file_get', 'path': created['marker']['path'], 'target': record['target']},
                {'t': 'capabilities', 'target': record['target']}]
    require(len(record.get('requests', [])) == 3, 'Read must contain only capabilities/file_get/capabilities')
    values = []
    for event, message in zip(record['requests'], messages):
        require(event.get('message') == message and event.get('host_timed_out') is False, 'Read request differs or writes guest')
        values.append(response(event, message))
    for index in (0, 2): capabilities_valid(values[index], record['target'])
    require(type(values[1].get('size')) is int and values[1]['size'] == len(content)
            and base64.b64decode(values[1].get('data', ''), validate=True) == content, 'Actual file_get bytes differ')
    return record


def formal(inputs, name, cli, arguments, offline=False):
    value = inputs.json(name)
    require(type(value.get('exit_code')) is int and value['exit_code'] == 0
            and value.get('command') == (OFFLINE if offline else []) + [cli] + arguments, 'Formal command failed or args differ: ' + name)
    return value


def validate_stop_cleanup(inputs, label, boot, clone, baseline):
    formal(inputs, label + '-vm-launch.json', CLI4, ['vm', 'launch', 'task8-copy', '--library-root', LIBRARY, '--headless'])
    formal(inputs, label + '-vm-stop.json', CLI4, ['vm', 'stop', 'task8-copy', '--library-root', LIBRARY])
    stop = inputs.raw(label + '-vm-stop.log').decode()
    require('boot instance ' + boot['target']['instance_id'] in stop and 'sending SIGINT to ' + str(boot['target']['pid']) in stop
            and 'task8-copy: stopped' in stop, 'Stop log does not match accepted instance')
    launch = inputs.raw(label + '-vm-launch.log').decode()
    require('[vphone] Guest stopped' in launch and 'graceful shutdown via guest power-off command over vsock' in launch, 'Formal launch did not record graceful guest stop')
    cleanup = inputs.json(label + '-post-boot-cleanup.json')
    require(cleanup.get('passed') is True and cleanup.get('label') == label
            and all(cleanup.get(key) is True for key in ('source_metadata_unchanged', 'test_file_identities_unchanged', 'binding_unchanged', 'receipt_unchanged'))
            and cleanup.get('task8_processes') == cleanup.get('task8_attachments') == []
            and cleanup.get('pending_transaction') is False and cleanup.get('desired_pending') is False, 'Post-stop cleanup failed')
    require(set(cleanup['source_metadata']) == set(cleanup['test_metadata']) == FILES, 'Cleanup six-file set differs')
    for name in FILES:
        for key in ('device', 'inode', 'size', 'mtime_ns', 'ctime_ns'):
            require(cleanup['source_metadata'][name][key] == clone['source_before'][name][key], 'Source metadata changed')
        for key in ('device', 'inode', 'size'):
            require(cleanup['test_metadata'][name][key] == clone['target_files'][name][key], 'Target file identity changed')
    require(cleanup['static_test_file_sha256'] == {name: baseline[VM][name]['sha256'] for name in ('config.plist', 'AVPBooter.vresearch1.bin', 'AVPSEPBooter.vresearch1.bin')}, 'Static config/ROM digest changed')
    return cleanup


def validate_commit(inputs, label, transaction, version, target=None):
    commit = inputs.json(label + '-readback.json'); before = inputs.json(label + '-before.json')
    names = {kind: label + '-committed-' + kind + '.json' for kind in ('journal', 'report', 'component-receipts', 'installed-component-proof')}
    journal, report, publication, proof = [inputs.json(names[key]) for key in ('journal', 'report', 'component-receipts', 'installed-component-proof')]
    canonical_uuid(transaction)
    require(commit.get('passed') is True and commit.get('transaction_id') == journal.get('id') == proof.get('transactionID') == publication.get('transactionID') == transaction
            and commit.get('journal_version') == journal.get('version') == version
            and journal.get('kernelOnly') is True and journal.get('phase') == 'committed'
            and journal.get('vmPath') in (VM, VM.removeprefix('/private'))
            and commit.get('pending') is False and commit.get('remaining_attachments') == [], 'Committed readback/journal state differs')
    require(before.get('passed') is True and before.get('vm') == VM and set(before['files']) == set(commit['files']) == FILES
            and before.get('pending') is False and before.get('final_pending') is False
            and before.get('task8_attachments') == before.get('final_task8_attachments') == [], 'Operation baseline failed')
    disk = journal['kernelDisk']; kernel = commit['kernel']; receipt = publication['installed']
    require(disk.get('direction') == 'forward' and disk.get('pending') is False and type(disk.get('cursor')) is int
            and disk['cursor'] == len(disk['offsets']) and disk['originalSHA256'] == before['files']['Disk.img']['sha256']
            and disk['candidateSHA256'] == commit['files']['Disk.img']['sha256'] == commit.get('disk_sha256_after_readonly') == proof['imageSHA256'], 'Disk publication/readback relationship differs')
    require(disk['identity']['diskDevice'] == before['files']['Disk.img']['metadata']['st_dev']
            and disk['identity']['diskInode'] == before['files']['Disk.img']['metadata']['st_ino']
            and disk['size'] == before['files']['Disk.img']['metadata']['st_size'], 'Disk journal/baseline identity differs')
    require(commit.get('proof') == proof and commit.get('receipt') == receipt and publication.get('schemaVersion') == proof.get('schemaVersion') == receipt.get('schemaVersion') == 1
            and publication.get('originLayer') == 'kernel' and publication.get('records') == []
            and receipt.get('state') == 'committed' and receipt.get('scope') == 'installedComponent' and receipt.get('component') == 'kernelcache'
            and receipt['outputs'] == [{'path': 'Disk.img', 'sha256': disk['candidateSHA256']}], 'Committed proof/receipt scope differs')
    require(inputs.digest(names['component-receipts']) == journal['componentReceiptsSHA256']
            and inputs.digest(names['report']) == journal['reportSHA256']
            and inputs.digest(names['installed-component-proof']) == publication['originProofSHA256'], 'Committed raw JSON digest chain differs')
    require(proof.get('producer') == 'current-bundle-kernel-update' and proof.get('rollbackProtocol') == 'vphone.kernel-rollback.v1'
            and proof.get('version') == V9 and proof.get('executableSHA256') == CLI_SHA
            and kernel.get('readonly') is True and kernel.get('im4m_im4r_preserved') is True and kernel.get('ordered_reconstruction_equals_actual_payload') is True
            and kernel['payload_sha256'] == proof['payloadSHA256'] and kernel['im4p_sha256'] == proof['im4pSHA256']
            and kernel['container_envelope_sha256'] == proof['containerEnvelopeSHA256'], 'Trusted producer/kernel readback association differs')
    for name in FILES:
        require(commit['files'][name].get('identity_unchanged') is True and commit['files'][name]['inode'] == before['files'][name]['metadata']['st_ino'], 'Readback file identity differs')
        if name != 'Disk.img': require(commit['files'][name]['sha256'] == before['files'][name]['sha256'] and commit['files'][name].get('content_unchanged') is True, 'Non-Disk file changed during operation')
    records = [record for component in report['components'] for record in component.get('records', [])]
    require([effect['record'] for effect in receipt['effects']] == records and all(effect['outputPath'] == 'Disk.img' for effect in receipt['effects']), 'Report/receipt effects differ')
    expected = inputs.json(label + '-operation-expectations.json')
    require(commit.get('expected') == expected and commit.get('expectations_sha256') == inputs.digest(label + '-operation-expectations.json')
            and expected['version'] == V9 and expected['executableSHA256'] == CLI_SHA and expected['plan'] == journal['plan']
            and expected['planSHA256'] == receipt['planSHA256'] and expected['desiredSHA256'] == receipt['desiredSHA256'] == journal['options']['desiredSHA256'], 'Frozen operation expectations differ')
    require(before['desired_sha256'] == DESIRED_B_SHA and before['desired']['generationID'] == receipt['generationID'] == journal['options']['generationID'], 'Live desired/generation differs')
    metadata = {entry['name']: entry for entry in journal['metadata']}
    require(len(metadata) == len(journal['metadata']) and set(metadata) == {'.firmware-component-receipts.json', 'launchpad.json'}
            and metadata['.firmware-component-receipts.json']['original'] == before['receipt_sha256']
            and metadata['.firmware-component-receipts.json']['output'] == inputs.digest(names['component-receipts'])
            and metadata['launchpad.json']['original'] == before['binding_sha256'], 'Publication metadata CAS differs')
    if target is None:
        require(version == 3 and expected['operation'] == 'update' and 'rollbackSelection' not in journal, 'Expected normal historical B publication')
        arguments = ['vm', 'update-kernel', 'task8-copy', '--library-root', LIBRARY]
    else:
        selection = journal['rollbackSelection']
        require(version == 4 and expected['operation'] == 'rollback' and proof.get('operation') == 'kernel-rollback'
                and selection == commit.get('rollback_selection') and selection['targetTransactionID'] == proof['targetTransactionID'] == expected['targetTransactionID'] == target
                and selection['liveDesiredSHA256'] == proof['liveDesiredSHA256'] == before['desired_sha256']
                and selection['bindingSHA256'] == proof['bindingSHA256'] == before['binding_sha256']
                and selection['targetDesired']['plan'] == journal['plan'] and selection['targetDesired']['planSHA256'] == receipt['planSHA256']
                and proof['targetDesiredSHA256'] == receipt['desiredSHA256']
                and selection['targetEvidenceSHA256'] == proof['targetEvidenceSHA256']
                and selection['targetPayloadSHA256'] == expected['targetPayloadSHA256'] == kernel['payload_sha256']
                and selection['targetIM4PSHA256'] == expected['targetIM4PSHA256'] == kernel['im4p_sha256']
                and selection['sourceVersion'] == V9 and selection['sourceExecutableSHA256'] == CLI_SHA, 'Schema4 target/live CAS contract differs')
        arguments = ['vm', 'rollback-kernel', 'task8-copy', '--library-root', LIBRARY, '--to-transaction', target]
    formal(inputs, label + '.json', CLI9, arguments, offline=True)
    return commit, journal, publication, proof, before, names


def validate_rebind(inputs, label, before_binding, receipt_sha, desired_sha, journal_sha, proof_sha, target_version):
    check = inputs.json(label + '-host-rebind-check.json')
    require(check.get('passed') is True and check.get('exit_code') == 0 and check.get('target_version') == target_version
            and check.get('command') == [CLI9, 'vm', 'bind-core-bundle', 'task8-copy', '--library-root', LIBRARY, '--version', target_version], 'Formal host rebind differs')
    before, after = check['before'], check['after']
    require(before['binding'] == before_binding and after['binding'] == dict(before_binding, bundle=target_version), 'Rebind changed kernel/binding scope')
    for key, value in [('receipt_sha256', receipt_sha), ('desired_sha256', desired_sha), ('journal_sha256', journal_sha), ('proof_sha256', proof_sha)]:
        require(before[key] == after[key] == value, 'Rebind changed ' + key)
    require(set(before['files_metadata']) == set(after['files_metadata']) == FILES and before['files_metadata'] == after['files_metadata'], 'Rebind changed six-file metadata')
    owner = inputs.json(label + '-binding-owner-check.json')
    require(owner.get('passed') is True and owner.get('rebind_label') == label and owner.get('binding_sha256') == after['binding_sha256']
            and owner['before']['inode'] == owner['after']['inode'] and owner['before']['mode'] == owner['after']['mode'] == 0o600
            and owner['before']['gid'] == owner['after']['gid'] == 0 and owner['after']['uid'] == 2035870432, 'Binding owner repair changed scope')
    return check


def verify(evidence):
    inputs = FrozenInputs(evidence)
    result = {'schemaVersion': 1, 'passed': False, 'status': 'refused', 'scope': 'Saved-file evidence join for original Documents marker, same-A reboot, then distinct-payload schema4 rollback to historical B; historical tmp failure retained',
              'old_tmp_failure_preserved': False, 'same_kernel_reboot_verified': False, 'cross_rollback_documents_verified': False,
              'historical_v2_join': 'Not rewritten, run or passed by this tool', 'missing': []}
    try:
        old = inputs.json(ORIGIN + '-marker-read.json')
        require(inputs.digest(ORIGIN + '-marker-read.json') == OLD_FAILURE_SHA and old.get('passed') is False, 'Historical tmp failure was changed')
        require(old['marker']['path'] == '/private/var/tmp/task8-kernel-rollback-682d8cbe-429b-4c4a-95fb-e6dfa945aa35'
                and any(event.get('response', {}).get('ok') is False and event['response'].get('error') == 'open failed: No such file or directory' for event in old.get('requests', [])), 'Original ENOENT observation differs')
        result['old_tmp_failure_preserved'] = True
        clone, baseline = inputs.json('clone.json'), inputs.json('baseline-digests.json')
        require(clone.get('target') == VM and clone.get('source_metadata_unchanged') is True and clone.get('source_before') == clone.get('source_after')
                and set(clone['source_before']) == set(clone['target_files']) == FILES, 'Saved source/clone boundary differs')
        created, content = validate_create(inputs)
        a, aj, ap, aproof, abefore, anames = validate_commit(inputs, ORIGIN, A_TX, 4, 'c0a0a7a8-3677-4a44-aa36-f370bb67b5ca')
        require(a['kernel']['payload_sha256'] == PAYLOAD_A, 'Original A payload differs')
        aboot = validate_boot(inputs, ORIGIN, anames['component-receipts'], a)
        require(created['target'] == aboot['target'] and created['expected'] == aboot['expected']
                and created.get('source_boot_evidence') == str(E / (ORIGIN + '-boot-watch.json'))
                and created.get('source_boot_sha256') == inputs.digest(ORIGIN + '-boot-watch.json'), 'Create/source boot association differs')
        validate_stop_cleanup(inputs, ORIGIN, aboot, clone, baseline)
        reboot = validate_boot(inputs, REBOOT, anames['component-receipts'], a)
        require(reboot['expected'] == aboot['expected'], 'Same-A reboot changed installed metadata')
        reboot_read = validate_read(inputs, REBOOT, created, content, reboot)
        validate_stop_cleanup(inputs, REBOOT, reboot, clone, baseline)
        preboot = inputs.json(REBOOT + '-pre-boot-check.json')
        require(preboot.get('passed') is True and preboot.get('expected') == reboot['expected']
                and preboot.get('old_marker_failure_sha256') == OLD_FAILURE_SHA and preboot.get('persistent_create_sha256') == CREATE_SHA
                and preboot.get('signals_sent') == preboot.get('task8_processes') == preboot.get('task8_attachments') == []
                and preboot.get('pending') is False and preboot.get('frozen_source16') is True
                and preboot.get('frozen_v9_cli') is True and preboot.get('frozen_v4_cli_vm') is True, 'Reboot pre-stop/frozen boundary differs')
        preflight = inputs.json(REBOOT + '-v4-preflight.json')
        require(type(preflight.get('exit_code')) is int and preflight['exit_code'] == 0 and preflight.get('command') == [VM4, '--help'], 'Reboot V4 preflight failed or changed')
        require(reboot['target']['process_started_at'] > created['target']['process_started_at']
                and reboot['target']['instance_id'].upper() != created['target']['instance_id'].upper(), 'Same-A reboot did not use new instance')
        result.update(same_kernel_reboot_verified=True, marker_path=created['marker']['path'], marker_sha256=sha(content), marker_size=len(content))
        future = [ROLLBACK + suffix for suffix in ('.json', '-readback.json', '-committed-journal.json', '-committed-report.json', '-committed-component-receipts.json',
                    '-committed-installed-component-proof.json', '-boot-expectations.json', '-boot-watch.json', '-marker-v2-read.json', '-vm-launch.json', '-vm-launch.log', '-vm-stop.json', '-vm-stop.log',
                    '-post-boot-cleanup.json', '-host4-host-rebind-check.json', '-host4-binding-owner-check.json')]
        for name in future:
            try: inputs.raw(name)
            except FileNotFoundError: result['missing'].append(name)
        if result['missing']: raise Pending('Final R_B publication/readback/boot/read/cleanup evidence is incomplete')
        b, bj, bp, bproof, bbefore, bnames = validate_commit(inputs, HISTORY, B_TX, 3)
        require(inputs.digest(bnames['component-receipts']) == old['marker']['expected']['receipt_sha256'], 'Historical B publication differs from preserved original evidence')
        rb, rj, rp, rproof, before, rnames = validate_commit(inputs, ROLLBACK, RB_TX, 4, B_TX)
        require(rb['transaction_id'] not in (A_TX, B_TX) and rb['kernel']['payload_sha256'] == b['kernel']['payload_sha256'] == PAYLOAD_B
                and rb['kernel']['payload_sha256'] != a['kernel']['payload_sha256'], 'Rollback did not publish different historical B payload')
        for field in ('im4p_sha256', 'img4_sha256', 'description', 'payp_sha256', 'im4m_sha256', 'container_envelope_sha256'):
            require(rb['kernel'][field] == b['kernel'][field], 'Actual B kernel envelope differs: ' + field)
        for field in ('description', 'payp_sha256', 'im4m_sha256', 'container_envelope_sha256'):
            require(rb['kernel'][field] == a['kernel'][field], 'Rollback did not preserve original envelope: ' + field)
        target_evidence = sha(inputs.raw(bnames['journal']) + inputs.raw(bnames['report']) + inputs.raw(bnames['component-receipts'])
                              + inputs.raw(bnames['installed-component-proof']) + b['kernel']['im4p_sha256'].encode())
        require(rproof['targetEvidenceSHA256'] == target_evidence and rb['receipt']['planSHA256'] == b['receipt']['planSHA256']
                and rb['receipt']['desiredSHA256'] == b['receipt']['desiredSHA256'] == DESIRED_B_SHA, 'Historical target evidence/desired association differs')
        require(before['receipt'] == ap and before['receipt_sha256'] == inputs.digest(anames['component-receipts'])
                and inputs.raw(ROLLBACK + '-before-receipt.json') == inputs.raw(anames['component-receipts'])
                and inputs.digest(ROLLBACK + '-before-desired.json') == before['desired_sha256'] == DESIRED_B_SHA
                and inputs.digest(ROLLBACK + '-before-binding.json') == before['binding_sha256'], 'Post-reboot baseline/current desired/receipt differs')
        source_rebind = validate_rebind(inputs, ROLLBACK + '-source9', reboot['expected']['binding'], inputs.digest(anames['component-receipts']), DESIRED_B_SHA,
                                         inputs.digest(anames['journal']), inputs.digest(anames['installed-component-proof']), V9)
        require(source_rebind['before']['binding_sha256'] == reboot['expected']['binding_sha256']
                and source_rebind['after']['binding_sha256'] == before['binding_sha256'] and source_rebind['after']['binding'] == before['binding'], 'Source9 rebind/baseline association differs')
        host4 = validate_rebind(inputs, ROLLBACK + '-host4', rb['binding'], inputs.digest(rnames['component-receipts']), DESIRED_B_SHA,
                               inputs.digest(rnames['journal']), inputs.digest(rnames['installed-component-proof']), V4)
        require(host4['before']['binding_sha256'] == next(entry['output'] for entry in rj['metadata'] if entry['name'] == 'launchpad.json'), 'Host4 rebind did not start from committed binding bytes')
        rboot = validate_boot(inputs, ROLLBACK, rnames['component-receipts'], rb)
        require(rboot['expected']['binding_sha256'] == host4['after']['binding_sha256'], 'Final boot binding differs from formal rebind')
        restored = validate_read(inputs, ROLLBACK, created, content, rboot)
        require(restored['vm_identity'] == reboot_read['vm_identity'] and rboot['target']['process_started_at'] > reboot['target']['process_started_at']
                and len({created['target']['instance_id'].upper(), reboot['target']['instance_id'].upper(), rboot['target']['instance_id'].upper()}) == 3, 'Cross-rollback read did not use third newer instance')
        validate_stop_cleanup(inputs, ROLLBACK, rboot, clone, baseline)
        result.update(passed=True, status='passed', cross_rollback_documents_verified=True, transaction_ids=[A_TX, RB_TX], historical_target=B_TX,
                      payloads=[PAYLOAD_A, PAYLOAD_B], boot_targets=[created['target'], reboot['target'], rboot['target']],
                      desired_sha256=DESIRED_B_SHA, post_reboot_starting_disk_sha256=before['files']['Disk.img']['sha256'],
                      dsc_scope='Official producer/commit validation and saved actual readback; this tool does not independently rerun DSC or read disks')
    except FileNotFoundError as error:
        result.update(status='pending', error='Required saved evidence is missing: ' + str(error))
    except Pending as error:
        result.update(status='pending', error=str(error))
    except BaseException as error:
        result.update(status='refused', error=type(error).__name__ + ': ' + str(error))
    finally:
        try: inputs.recheck()
        except BaseException as error: result.update(passed=False, status='refused', input_stability_error=type(error).__name__ + ': ' + str(error))
        result['inputs_sha256'] = inputs.hashes()
    return result


def reserve_output(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    return os.fdopen(fd, 'wb')


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    args = parser.parse_args(arguments)
    require(isinstance(args.label, str) and len(args.label) <= 100 and re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', args.label), 'Invalid fresh output label')
    path = E / (args.label + '-documents-persistence.json')
    with reserve_output(path) as output:
        result = verify(FileEvidence())
        output.write((json.dumps(result, indent=2, allow_nan=False) + '\n').encode()); output.flush(); os.fsync(output.fileno())
    print(json.dumps({'passed': result['passed'], 'status': result['status'], 'output': str(path), 'missing': result['missing']}), flush=True)
    return 0 if result['passed'] else 2 if result['status'] == 'pending' else 1


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    try: sys.exit(main())
    except Exception as error:
        print(type(error).__name__ + ': ' + str(error), file=sys.stderr); sys.exit(1)

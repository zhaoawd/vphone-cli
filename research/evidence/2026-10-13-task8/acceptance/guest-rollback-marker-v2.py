"""Task8 Documents marker with explicit sync and same-instance readback.
Only the fixed V4 CLI guest API is used. No bootstrap, VM or AMFI operation.
"""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shlex
import stat
import subprocess
import sys
import uuid

E = Path(__file__).resolve().parent
VM = Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
CLI = '/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-cli'
HOST = '2.6.20261016-local'
PROTOCOL = 'task8.guest-marker.v2'
DIRECTORY = '/private/var/mobile/Documents'
SYNC_PATHS = ('/bin/sync', '/var/jb/usr/bin/sync')
PROBE = "if [ -x /bin/sync ]; then printf '%s\\n' /bin/sync; elif [ -x /var/jb/usr/bin/sync ]; then printf '%s\\n' /var/jb/usr/bin/sync; else exit 69; fi"
LABEL = re.compile(r'[a-z0-9]+(?:-[a-z0-9]+)*\Z')
SHA = re.compile(r'[0-9a-f]{64}\Z')


def require(condition, message):
    if not condition: raise RuntimeError(message)


def valid_label(value):
    require(isinstance(value, str) and len(value) <= 80 and LABEL.fullmatch(value), 'Invalid evidence label')


def sha(data): return hashlib.sha256(data).hexdigest()


def canonical(value): return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def decode_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON field: ' + key); result[key] = value
        return result
    def invalid(value): raise RuntimeError('Invalid JSON constant: ' + value)
    result = json.loads(data, object_pairs_hook=pairs, parse_constant=invalid)
    require(isinstance(result, dict), 'Expected JSON object')
    return result


def strict_read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        first = os.fstat(fd)
        require(stat.S_ISREG(first.st_mode) and first.st_nlink == 1 and 0 < first.st_size <= 16 << 20, 'Invalid ordinary evidence file')
        parts, size = [], 0
        while True:
            part = os.read(fd, min(1 << 20, (16 << 20) + 1 - size))
            if not part: break
            parts.append(part); size += len(part)
            require(size <= 16 << 20, 'Evidence exceeded size limit')
        after, named = os.fstat(fd), os.lstat(path)
        keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_nlink')
        require(size == first.st_size and all(getattr(first, key) == getattr(after, key) == getattr(named, key) for key in keys), 'Evidence changed during read')
        return b''.join(parts)
    finally: os.close(fd)


def exclusive_output(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    return os.fdopen(fd, 'wb')


def cli_command(message):
    return [CLI, 'guest', 'send', 'task8-copy', '--library-root', str(VM.parent), '--timeout', '75',
            json.dumps(message, separators=(',', ':'))]


class NativeOperations:
    def read(self, path): return strict_read(path)
    def pending(self):
        for name in ('.firmware-transaction', '.firmware-desired-pending.json'):
            try: os.lstat(VM / name)
            except FileNotFoundError: continue
            return True
        return False
    def new_uuid(self): return str(uuid.uuid4())
    def intent(self, label, marker):
        with exclusive_output(E / (label + '-marker-v2-intent.json')) as output:
            output.write(canonical(marker)); output.flush(); os.fsync(output.fileno())
    def request(self, message):
        command = cli_command(message)
        try:
            process = subprocess.run(command, capture_output=True, text=True, timeout=90)
            return dict(command=command, exit_code=process.returncode, stdout=process.stdout, stderr=process.stderr, host_timed_out=False)
        except subprocess.TimeoutExpired as error:
            def text(value): return value.decode(errors='replace') if isinstance(value, bytes) else value or ''
            return dict(command=command, exit_code=None, stdout=text(error.stdout), stderr=text(error.stderr), host_timed_out=True)


def validate_target(target):
    require(isinstance(target, dict) and set(target) == {'vm', 'instance_id', 'pid', 'process_started_at'}, 'Incomplete instance target')
    require(target['vm'] == 'task8-copy' and type(target['pid']) is int and target['pid'] > 0, 'Wrong VM target')
    require(isinstance(target['instance_id'], str) and str(uuid.UUID(target['instance_id'])).upper() == target['instance_id'].upper(), 'Invalid instance UUID')
    started = target['process_started_at']
    require(type(started) in (int, float) and math.isfinite(started) and started > 0, 'Invalid instance start time')


def validate_expected(expected):
    require(isinstance(expected, dict) and isinstance(expected.get('binding'), dict) and expected['binding'].get('bundle') == HOST, 'Expected fixed V4 binding')
    for key in ('binding_sha256', 'receipt_sha256', 'desired_sha256', 'payload_sha256'):
        require(isinstance(expected.get(key), str) and SHA.fullmatch(expected[key]), 'Invalid expected digest: ' + key)
    transaction = expected.get('transaction_id')
    require(isinstance(transaction, str) and str(uuid.UUID(transaction)) == transaction, 'Invalid expected transaction UUID')


def inputs(operations, expected):
    require(not operations.pending(), 'Pending firmware or desired-plan transaction')
    raw = {name: operations.read(VM / name) for name in ('launchpad.json', '.firmware-component-receipts.json', '.firmware-desired-plan.json', 'config.plist')}
    require(sha(raw['launchpad.json']) == expected['binding_sha256'] and decode_json(raw['launchpad.json']) == expected['binding'], 'Current binding differs from boot evidence')
    require(sha(raw['.firmware-component-receipts.json']) == expected['receipt_sha256'], 'Current receipt differs from boot evidence')
    require(sha(raw['.firmware-desired-plan.json']) == expected['desired_sha256'], 'Current desired differs from boot evidence')
    publication = decode_json(raw['.firmware-component-receipts.json']); desired = decode_json(raw['.firmware-desired-plan.json'])
    installed = publication.get('installed')
    require(publication.get('schemaVersion') == 1 and publication.get('transactionID') == expected['transaction_id']
            and isinstance(installed, dict) and installed.get('scope') == 'installedComponent'
            and installed.get('state') == 'committed' and installed.get('component', '').lower() == 'kernelcache', 'Receipt has no matching installed kernel')
    generation = installed.get('generationID')
    require(isinstance(generation, str) and SHA.fullmatch(generation) and desired.get('schemaVersion') == 1
            and desired.get('generationID') == generation, 'Current receipt/desired generation differs')
    # The installed target plan and live desired may differ after schema4 rollback.
    config = plistlib.loads(raw['config.plist']); machine = config.get('machineIdentifier')
    require(isinstance(machine, bytes) and machine, 'Missing stable VM machine identifier')
    require(not operations.pending(), 'Transaction appeared during input observation')
    return {'vm_directory': str(VM), 'machine_identifier_sha256': sha(machine), 'generation_id': generation,
            'config_sha256': sha(raw['config.plist'])}


def shell_success(response):
    require(response.get('ok') is True and type(response.get('code')) is int and response['code'] == 0
            and response.get('timed_out') is False and response.get('truncated') is False
            and isinstance(response.get('stdout'), str) and isinstance(response.get('stderr'), str), 'Shell did not complete successfully without timeout/truncation')


def capabilities(response, target):
    commands = response.get('commands', {})
    require(response.get('target') == target and response.get('boot_mode') == 'normal' and response.get('guest_connected') is True
            and commands.get('shell') is True and commands.get('file_get') is True, 'Guest capabilities/instance differ')


def marker_content(marker):
    return canonical({'schemaVersion': 2, 'protocol': PROTOCOL, 'purpose': 'Task8 committed kernel rollback persistent guest marker',
        'uuid': marker['uuid'], 'created_by_instance': marker['target'], 'installed_expectations': marker['expected'],
        'source_boot_label': marker['source_boot_label'], 'created_evidence_label': marker['created_evidence_label'],
        'vm_identity': marker['vm_identity']})


def validate_previous(previous, previous_label, target, identity):
    require(previous.get('schemaVersion') == 2 and previous.get('protocol') == PROTOCOL
            and previous.get('passed') is True and previous.get('mode') == 'create'
            and previous.get('evidence_label') == previous_label, 'Previous record is not a successful v2 create')
    valid_label(previous.get('boot_label')); validate_target(previous.get('target')); validate_expected(previous.get('expected'))
    old_target = previous['target']
    require(old_target['vm'] == target['vm'] and old_target['instance_id'].upper() != target['instance_id'].upper()
            and target['process_started_at'] > old_target['process_started_at'], 'Read requires a new instance of the same VM')
    marker = previous.get('marker'); require(isinstance(marker, dict), 'Previous marker missing')
    token = marker.get('uuid')
    require(isinstance(token, str) and str(uuid.UUID(token)) == token and uuid.UUID(token).version == 4, 'Marker UUID is not canonical v4')
    require(marker.get('path') == DIRECTORY + '/task8-kernel-rollback-' + token, 'Marker must stay in the fixed Documents directory')
    require(marker.get('target') == old_target and marker.get('expected') == previous['expected']
            and marker.get('source_boot_label') == previous['boot_label'] and marker.get('created_evidence_label') == previous_label
            and marker.get('vm_identity') == previous.get('vm_identity') == identity, 'Previous marker VM/provenance differs')
    content = base64.b64decode(marker.get('content_base64', ''), validate=True)
    require(content == marker_content(marker) and 0 < len(content) <= 16384 and type(marker.get('size')) is int
            and marker['size'] == len(content) and marker.get('content_sha256') == sha(content)
            and previous.get('downloaded_sha256') == sha(content) and previous.get('downloaded_size') == len(content), 'Previous marker bytes/digest/readback differ')
    sync = previous.get('sync'); require(isinstance(sync, dict) and sync.get('executable') in SYNC_PATHS, 'Previous successful sync missing')
    index = sync.get('request_index'); requests = previous.get('requests')
    require(type(index) is int and isinstance(requests, list) and 0 <= index < len(requests), 'Previous sync request association missing')
    event = requests[index]
    require(event.get('message') == {'t': 'shell', 'cmd': 'exec ' + sync['executable'], 'timeout_ms': 60000, 'target': old_target}
            and type(event.get('exit_code')) is int and event['exit_code'] == 0 and event.get('host_timed_out') is False
            and event.get('response') == sync.get('response'), 'Previous sync request differs')
    shell_success(sync['response'])
    require(len(requests) == 6 and index == 3, 'Previous create request sequence differs')
    expected_messages = [
        {'t': 'capabilities', 'target': old_target},
        {'t': 'shell', 'cmd': PROBE, 'timeout_ms': 10000, 'target': old_target},
        {'t': 'shell', 'cmd': '(set -C && printf %s ' + shlex.quote(content.decode()) + ' > ' + shlex.quote(marker['path']) + ')', 'timeout_ms': 10000, 'target': old_target},
        {'t': 'shell', 'cmd': 'exec ' + sync['executable'], 'timeout_ms': 60000, 'target': old_target},
        {'t': 'file_get', 'path': marker['path'], 'target': old_target},
        {'t': 'capabilities', 'target': old_target}]
    for event, message in zip(requests, expected_messages):
        require(event.get('message') == message and event.get('command') == cli_command(message)
                and type(event.get('exit_code')) is int and event['exit_code'] == 0 and event.get('host_timed_out') is False
                and decode_json(event.get('stdout', '')) == event.get('response') and event['response'].get('ok') is True,
                'Previous create request/response evidence differs')
    for number in (1, 2, 3): shell_success(requests[number]['response'])
    require(requests[1]['response']['stdout'] == sync['executable'] + '\n', 'Previous sync discovery differs')
    capabilities(requests[0]['response'], old_target); capabilities(requests[5]['response'], old_target)
    downloaded = requests[4]['response']
    require(type(downloaded.get('size')) is int and downloaded['size'] == len(content)
            and base64.b64decode(downloaded.get('data', ''), validate=True) == content, 'Previous actual file_get bytes differ')
    return marker, content


def perform(mode, boot_label, label, previous_label, operations):
    record = {'schemaVersion': 2, 'protocol': PROTOCOL, 'passed': False, 'mode': mode,
              'boot_label': boot_label, 'evidence_label': label, 'requests': []}
    try:
        valid_label(boot_label); valid_label(label)
        require(mode in ('create', 'read') and ((mode == 'read') == (previous_label is not None)), 'Invalid marker mode/previous record')
        if previous_label is not None: valid_label(previous_label)
        boot_path = E / (boot_label + '-boot-watch.json'); boot_raw = operations.read(boot_path); boot = decode_json(boot_raw)
        require(boot.get('passed') is True, 'Source boot watch did not pass')
        target, expected = boot.get('target'), boot.get('expected'); validate_target(target); validate_expected(expected)
        record.update(target=target, expected=expected, source_boot_evidence=str(boot_path), source_boot_sha256=sha(boot_raw))
        identity = inputs(operations, expected); record['vm_identity'] = identity
        def check():
            require(operations.read(boot_path) == boot_raw and inputs(operations, expected) == identity, 'Boot/current VM inputs changed')
        def send(message):
            require(message.get('target') == target, 'Request has a different instance target')
            check(); event = operations.request(message); event['message'] = message; record['requests'].append(event)
            require(event.get('host_timed_out') is False and type(event.get('exit_code')) is int and event['exit_code'] == 0, 'Host CLI failed or timed out')
            response = decode_json(event.get('stdout', '')); event['response'] = response
            require(response.get('ok') is True, 'Guest request failed')
            return response
        if mode == 'read':
            previous_path = E / (previous_label + '-marker-v2-create.json')
            previous_raw = operations.read(previous_path); previous = decode_json(previous_raw)
            marker, content = validate_previous(previous, previous_label, target, identity)
            old_boot_path = E / (previous['boot_label'] + '-boot-watch.json')
            old_boot_raw = operations.read(old_boot_path); old_boot = decode_json(old_boot_raw)
            require(previous.get('source_boot_evidence') == str(old_boot_path) and previous.get('source_boot_sha256') == sha(old_boot_raw)
                    and old_boot.get('passed') is True and old_boot.get('target') == previous['target']
                    and old_boot.get('expected') == previous['expected'], 'Previous source boot evidence differs')
            record.update(marker=marker, created_record=str(previous_path), created_record_sha256=sha(previous_raw))
        capabilities(send({'t': 'capabilities', 'target': target}), target)
        if mode == 'create':
            probe = send({'t': 'shell', 'cmd': PROBE, 'timeout_ms': 10000, 'target': target}); shell_success(probe)
            require(probe['stdout'] in tuple(path + '\n' for path in SYNC_PATHS) and not probe['stderr'], 'No exact supported sync executable')
            sync_path = probe['stdout'].rstrip('\n')
            token = operations.new_uuid()
            require(str(uuid.UUID(token)) == token and uuid.UUID(token).version == 4, 'Invalid new marker UUID')
            marker = {'uuid': token, 'path': DIRECTORY + '/task8-kernel-rollback-' + token, 'target': target,
                      'expected': expected, 'source_boot_label': boot_label, 'created_evidence_label': label, 'vm_identity': identity}
            content = marker_content(marker); require(0 < len(content) <= 16384, 'Marker is too large')
            marker.update(content_base64=base64.b64encode(content).decode(), content_sha256=sha(content), size=len(content))
            operations.intent(label, marker); record['marker'] = marker
            command = '(set -C && printf %s ' + shlex.quote(content.decode()) + ' > ' + shlex.quote(marker['path']) + ')'
            written = send({'t': 'shell', 'cmd': command, 'timeout_ms': 10000, 'target': target}); shell_success(written)
            index = len(record['requests'])
            synced = send({'t': 'shell', 'cmd': 'exec ' + sync_path, 'timeout_ms': 60000, 'target': target}); shell_success(synced)
            record['sync'] = {'executable': sync_path, 'request_index': index, 'response': synced}
        downloaded = send({'t': 'file_get', 'path': marker['path'], 'target': target})
        actual = base64.b64decode(downloaded.get('data', ''), validate=True)
        require(type(downloaded.get('size')) is int and downloaded['size'] == len(content)
                and actual == content and sha(actual) == marker['content_sha256'], 'Actual file_get bytes/digest/size differ')
        capabilities(send({'t': 'capabilities', 'target': target}), target)
        check(); record.update(downloaded_sha256=sha(actual), downloaded_size=len(actual), passed=True)
        if mode == 'read':
            require(operations.read(previous_path) == previous_raw and operations.read(old_boot_path) == old_boot_raw, 'Previous create/boot evidence changed')
    except BaseException as error:
        record['passed'] = False; record['error'] = type(error).__name__ + ': ' + str(error)
    return record


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('create', 'read'))
    parser.add_argument('--boot-label', required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--previous-create-label')
    args = parser.parse_args(arguments)
    valid_label(args.boot_label); valid_label(args.label)
    require((args.mode == 'read') == (args.previous_create_label is not None), 'read requires --previous-create-label; create forbids it')
    if args.previous_create_label is not None: valid_label(args.previous_create_label)
    path = E / (args.label + '-marker-v2-' + args.mode + '.json')
    with exclusive_output(path) as output:
        result = perform(args.mode, args.boot_label, args.label, args.previous_create_label, NativeOperations())
        output.write((json.dumps(result, indent=2) + '\n').encode()); output.flush(); os.fsync(output.fileno())
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    try: sys.exit(main())
    except Exception as error:
        print(type(error).__name__ + ': ' + str(error), file=sys.stderr); sys.exit(1)

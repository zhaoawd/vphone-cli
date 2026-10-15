"""Offline Task8 marker observations. Run only after the formal VM stop.

Missing markers are observations. Unreadable/encrypted volumes and unsafe cleanup
are failures. This tool does not diagnose the cause of a missing marker.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import uuid

E = Path(__file__).resolve().parent
VM = Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
TASK_ROOT = VM.parent
TX = '58597f0a-e94c-4f69-86af-b0fdfa9fd3f3'
TARGET_TX = 'c0a0a7a8-3677-4a44-aa36-f370bb67b5ca'
OLD_UUID = '682d8cbe-429b-4c4a-95fb-e6dfa945aa35'
OLD_SHA = '2f30a9afeae97959ee833db90f12cdd0b4c22c932257e1d8f689ce5b5958162f'
ORIGINAL_SHA = 'e8763d11ecba26d4e8c04a03bd45f69a4836b88c6551fa28e8994d74d5199575'
CANDIDATE_SHA = 'fd8c34e130d99ef75af90ee44fee6d0dcd2822048a53eb74c1cdb46ca8f23741'
CLI4 = '/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-cli'
SYNC_PROBE = "if [ -x /bin/sync ]; then printf '%s\\n' /bin/sync; elif [ -x /var/jb/usr/bin/sync ]; then printf '%s\\n' /var/jb/usr/bin/sync; else exit 69; fi"
FILES = {'Disk.img', 'nvram.bin', 'SEPStorage', 'config.plist', 'AVPBooter.vresearch1.bin', 'AVPSEPBooter.vresearch1.bin'}
IDENTITY = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_nlink')


def require(value, message):
    if not value: raise RuntimeError(message)


def sha(data): return hashlib.sha256(data).hexdigest()


def decode_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON field: ' + key)
            result[key] = value
        return result
    def invalid(value): raise RuntimeError('Non-finite JSON value: ' + value)
    result = json.loads(data, object_pairs_hook=pairs, parse_constant=invalid)
    require(isinstance(result, dict), 'Expected JSON object')
    return result


def metadata(value): return {key: getattr(value, key) for key in IDENTITY}


def read_fd(fd, limit=None):
    first = os.fstat(fd)
    require(stat.S_ISREG(first.st_mode) and first.st_nlink == 1, 'Expected one-link ordinary file')
    if limit is not None: require(0 <= first.st_size <= limit, 'File exceeds read limit')
    digest, chunks, size = hashlib.sha256(), [], 0
    while True:
        data = os.read(fd, 16 << 20)
        if not data: break
        size += len(data); digest.update(data)
        if limit is not None:
            require(size <= limit, 'File grew beyond read limit'); chunks.append(data)
    after = os.fstat(fd)
    require(metadata(first) == metadata(after) and size == first.st_size, 'File changed during read')
    return {'sha256': digest.hexdigest(), 'metadata': metadata(first)}, b''.join(chunks)


def observe_file(path, limit=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        result, data = read_fd(fd, limit)
        require(metadata(os.lstat(path)) == result['metadata'], 'File pathname identity changed')
        return result, data
    finally: os.close(fd)


def load_frozen(path, frozen, digests, raw=False):
    info, data = observe_file(path, 16 << 20)
    frozen[path] = (info, data); digests[str(path)] = info['sha256']
    return data if raw else decode_json(data)


def no_symlink_directory(path):
    require(path.is_absolute(), 'Absolute directory required')
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        require(stat.S_ISDIR(os.lstat(current).st_mode), 'Directory is missing or a symlink: ' + str(current))


def exclusive_output(path):
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600), 'wb')


def pending():
    found = []
    for name in ('.firmware-transaction', '.firmware-desired-pending.json'):
        try: os.lstat(VM / name)
        except FileNotFoundError: continue
        found.append(name)
    return found


def target_vm(target):
    require(isinstance(target, dict) and target.get('vm') == 'task8-copy'
            and type(target.get('pid')) is int and target['pid'] > 0, 'Wrong marker VM target')
    require(str(uuid.UUID(target['instance_id'])).upper() == target['instance_id'].upper(), 'Invalid instance UUID')


def shell_success(response):
    require(response.get('ok') is True and type(response.get('code')) is int and response['code'] == 0
            and response.get('timed_out') is False and response.get('truncated') is False,
            'Guest shell evidence did not complete successfully')


def validate_marker(record, intent, documents=False):
    # Validate argv independently of the message fields used by the v2 recorder.
    for event in record.get('requests', []):
        command = event.get('command')
        require(isinstance(command, list) and len(command) == 9
                and command[:7] == [CLI4, 'guest', 'send', 'task8-copy', '--library-root', str(TASK_ROOT), '--timeout']
                and command[7] == ('75' if documents else '15'), 'Create request CLI/target differs')
        message = decode_json(command[8]); require(message.get('target') == record.get('target'), 'Create request instance differs')
        if documents: require(event.get('message') == message and event.get('host_timed_out') is False, 'V2 request message/host timeout differs')
        require(type(event.get('exit_code')) is int and event['exit_code'] == 0 and event.get('host_timed_out', False) is False
                and decode_json(event.get('stdout', '')) == event.get('response') and event['response'].get('ok') is True,
                'Create request/response failed or differs')
    require(record.get('passed') is True and record.get('mode') == 'create', 'Successful create evidence required')
    target_vm(record.get('target'))
    marker = record.get('marker'); require(isinstance(marker, dict) and marker == intent, 'Marker/intent differs')
    require(marker.get('target') == record['target'] and marker.get('expected') == record.get('expected'), 'Marker provenance differs')
    content = base64.b64decode(marker.get('content_base64', ''), validate=True)
    require(0 < len(content) <= 16384 and type(marker.get('size')) is int and marker['size'] == len(content)
            and sha(content) == marker.get('content_sha256') == record.get('downloaded_sha256'), 'Marker size/digest differs')
    requests = record['requests']; messages = [decode_json(event['command'][8]) for event in requests]
    if documents:
        token = marker.get('uuid')
        require(isinstance(token, str) and str(uuid.UUID(token)) == token and uuid.UUID(token).version == 4, 'Invalid v2 marker UUID')
        require(marker.get('path') == '/private/var/mobile/Documents/task8-kernel-rollback-' + token, 'V2 Documents path differs')
        require(record.get('schemaVersion') == 2 and record.get('protocol') == 'task8.guest-marker.v2'
                and record.get('downloaded_size') == len(content), 'V2 create protocol/size differs')
        canonical = {'schemaVersion': 2, 'protocol': 'task8.guest-marker.v2', 'purpose': 'Task8 committed kernel rollback persistent guest marker',
                     'uuid': token, 'created_by_instance': marker['target'], 'installed_expectations': marker['expected'],
                     'source_boot_label': marker['source_boot_label'], 'created_evidence_label': marker['created_evidence_label'], 'vm_identity': marker['vm_identity']}
        require(content == (json.dumps(canonical, sort_keys=True, separators=(',', ':')) + '\n').encode(), 'V2 intent bytes differ')
        require(marker['created_evidence_label'] == record.get('evidence_label') and marker['source_boot_label'] == record.get('boot_label')
                and marker['vm_identity'] == record.get('vm_identity'), 'V2 label/VM identity differs')
        require(len(messages) == 6, 'V2 create request count differs')
        sync = record.get('sync', {}); require(sync.get('request_index') == 3
                and sync.get('executable') in ('/bin/sync', '/var/jb/usr/bin/sync')
                and sync.get('response') == requests[3]['response'], 'V2 explicit sync evidence missing')
        require(messages[3] == {'t': 'shell', 'cmd': 'exec ' + sync['executable'], 'timeout_ms': 60000, 'target': record['target']}, 'V2 sync request differs')
        require(messages[1] == {'t': 'shell', 'cmd': SYNC_PROBE, 'timeout_ms': 10000, 'target': record['target']}
                and requests[1]['response'].get('stdout') == sync['executable'] + '\n' and requests[1]['response'].get('stderr') == '', 'V2 sync discovery differs')
        shell_success(requests[1]['response'])
        shell_success(requests[3]['response']); file_index = 4
    else:
        require(record.get('label') == 'kernel-v9-plan-b-resumed' and marker.get('path') == '/private/var/tmp/task8-kernel-rollback-' + OLD_UUID
                and len(content) == 742 and sha(content) == OLD_SHA and len(messages) == 4, 'Fixed old B marker differs')
        require(record['expected'].get('transaction_id') == '2901d975-2379-4b50-9340-8580786aacc1', 'Old marker is not from B')
        file_index = 2
    create_index = 2 if documents else 1
    require(messages[create_index] == {'t': 'shell', 'cmd': '(set -C && printf %s ' + shlex.quote(content.decode()) + ' > ' + shlex.quote(marker['path']) + ')',
                                        'timeout_ms': 10000, 'target': record['target']}, 'Create command differs from intent')
    shell_success(requests[create_index]['response'])
    require(messages[file_index] == {'t': 'file_get', 'path': marker['path'], 'target': record['target']}, 'Create file_get request differs')
    downloaded = requests[file_index]['response']
    require(type(downloaded.get('size')) is int and downloaded['size'] == len(content)
            and base64.b64decode(downloaded.get('data', ''), validate=True) == content, 'Actual create file_get bytes differ')
    for index in (0, len(requests) - 1):
        response = requests[index]['response']
        require(messages[index] == {'t': 'capabilities', 'target': record['target']} and response.get('target') == record['target']
                and response.get('boot_mode') == 'normal' and response.get('guest_connected') is True
                and response.get('commands', {}).get('shell') is True and response.get('commands', {}).get('file_get') is True, 'Create capabilities/instance differs')
    return marker, content


def read_marker(root, relative, expected):
    parts = relative.split('/')
    require(len(parts) == 2 and parts[0] in ('tmp', 'Documents') and re.fullmatch(r'task8-kernel-rollback-[0-9a-f-]{36}', parts[1]), 'Unsafe relative marker path')
    token = parts[1].removeprefix('task8-kernel-rollback-')
    require(str(uuid.UUID(token)) == token and uuid.UUID(token).version == 4, 'Unsafe relative marker UUID')
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    child = None
    try:
        try: child = os.open(parts[0], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
        except FileNotFoundError: return {'relative_path': relative, 'exists': False, 'missing_component': parts[0]}
        try: fd = os.open(parts[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=child)
        except FileNotFoundError: return {'relative_path': relative, 'exists': False, 'missing_component': parts[1]}
        try:
            result, data = read_fd(fd, 16384)
            named = os.stat(parts[1], dir_fd=child, follow_symlinks=False)
            require(metadata(named) == result['metadata'], 'Marker pathname identity changed')
            result.update(relative_path=relative, exists=True, content_matches=data == expected, content_base64=base64.b64encode(data).decode())
            return result
        finally: os.close(fd)
    finally:
        if child is not None: os.close(child)
        os.close(directory)


def backing_device(attachment):
    devices = [entry['dev-entry'] for entry in attachment.get('system-entities', []) if entry.get('content-hint') == 'GUID_partition_scheme']
    require(len(devices) == 1 and re.fullmatch(r'/dev/disk[0-9]+', devices[0]), 'Expected one GUID backing device')
    return devices[0]


def choose_volume(containers, device, name):
    physical = device.removeprefix('/dev/') + 's1'
    matches = [container for container in containers if [item.get('DeviceIdentifier') for item in container.get('PhysicalStores', [])] == [physical]]
    require(len(matches) == 1, 'APFS container does not have the exact backing physical store')
    container = matches[0]
    volumes = [volume for volume in container.get('Volumes', []) if volume.get('Name') == name]
    require(len(volumes) == 1, 'Expected one exact ' + name + ' volume')
    volume = volumes[0]
    require(re.fullmatch(r'disk[0-9]+s[0-9]+', volume.get('DeviceIdentifier', '')), 'Invalid APFS volume device')
    require(isinstance(volume.get('APFSVolumeUUID'), str) and str(uuid.UUID(volume['APFSVolumeUUID'])).upper() == volume['APFSVolumeUUID'].upper(), 'Invalid APFS volume UUID')
    require(all(volume[key] is False for key in ('Encrypted', 'Encryption', 'FileVault', 'Locked') if key in volume), 'Encrypted, locked or unrecognized encryption state is unsupported')
    return container, volume


def validate_volume_info(info, volume, physical, mount):
    require(info.get('DeviceIdentifier') == volume['DeviceIdentifier'] and info.get('VolumeUUID') == volume['APFSVolumeUUID']
            and info.get('VolumeName') == volume['Name'] and info.get('WritableVolume') is False
            and info.get('MountPoint') == str(mount), 'Mounted volume identity or readonly flag differs')
    require([item.get('APFSPhysicalStore') for item in info.get('APFSPhysicalStores', [])] == [physical], 'Mounted volume physical store differs')
    require(all(info[key] is False for key in ('Encrypted', 'Encryption', 'FileVault', 'Locked') if key in info), 'Encrypted, locked or unrecognized encryption state is unsupported')


class Operations:
    def __init__(self, record): self.record = record
    def run(self, command):
        event = {'command': command}; self.record['commands'].append(event)
        process = subprocess.run(command, capture_output=True, timeout=180)
        event.update(exit_code=process.returncode, stderr=process.stderr.decode(errors='replace'))
        if process.returncode: event['stdout'] = process.stdout.decode(errors='replace')
        require(process.returncode == 0, 'External command failed: ' + repr(command))
        return process.stdout
    def images(self): return plistlib.loads(self.run(['/usr/bin/hdiutil', 'info', '-plist'])).get('images', [])
    def attachments(self, image): return [item for item in self.images() if os.path.realpath(item.get('image-path', '')) == str(image)]
    def task8_attachments(self):
        prefix = str(TASK_ROOT) + '/'
        return [item for item in self.images() if os.path.realpath(item.get('image-path', '')).startswith(prefix)]
    def guard(self):
        require(not pending(), 'Pending firmware or desired-plan transaction')
        require(not self.task8_attachments(), 'Task8 image attachment already exists')
        processes = self.run(['/bin/ps', '-axo', 'pid=,command=']).decode(errors='strict')
        matches = [line for line in processes.splitlines() if 'vphone-vm' in line and
                   (str(VM) in line or '/tmp/vphone-task8-acceptance-vms/task8-copy' in line)]
        self.record.setdefault('stopped_checks', []).append({'matching_vm_processes': matches})
        require(not matches, 'Task8 VM process is active')


def inspect_image(operations, image, volume_name, relative, content, expected_sha=None, expected_size=None, expected_identity=None, require_exists=False):
    result = {'image': str(image), 'volume_name': volume_name, 'passed': False}
    operations.record['images'].append(result)
    device, base, initial, attach_attempted = None, None, None, False
    try:
        operations.guard()
        initial, _ = observe_file(image); result['before'] = initial
        if expected_sha is not None: require(initial['sha256'] == expected_sha, 'Archive image complete SHA differs from committed journal')
        if expected_size is not None: require(initial['metadata']['st_size'] == expected_size, 'Image size differs')
        if expected_identity is not None:
            require(all(initial['metadata'][key] == expected_identity[key] for key in ('st_dev', 'st_ino', 'st_size')), 'Current Disk identity differs')
        attach_attempted = True
        attached = plistlib.loads(operations.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nomount', '-nobrowse', '-plist', str(image)]))
        device = backing_device(attached); result['backing_guid_device'] = device
        active = operations.attachments(image)
        require(len(active) == 1 and backing_device(active[0]) == device, 'Attachment does not map back to exact image')
        result['attachment'] = active[0]
        containers = plistlib.loads(operations.run(['/usr/sbin/diskutil', 'apfs', 'list', '-plist']))['Containers']
        result['apfs_containers'] = containers
        container, volume = choose_volume(containers, device, volume_name)
        result.update(container=container, volume=volume, volume_uuid=volume['APFSVolumeUUID'], volume_roles=volume.get('Roles', []))
        base = Path(tempfile.mkdtemp(prefix='task8-marker-readonly-', dir='/private/tmp')); mount = base / volume_name; mount.mkdir()
        operations.run(['/sbin/mount_apfs', '-o', 'rdonly', '/dev/' + volume['DeviceIdentifier'], str(mount)])
        info = plistlib.loads(operations.run(['/usr/sbin/diskutil', 'info', '-plist', '/dev/' + volume['DeviceIdentifier']])); result['volume_info_before'] = info
        validate_volume_info(info, volume, device.removeprefix('/dev/') + 's1', mount)
        identity = metadata(os.lstat(mount)); result['mount_identity'] = identity
        result['marker'] = read_marker(mount, relative, content)
        after = plistlib.loads(operations.run(['/usr/sbin/diskutil', 'info', '-plist', '/dev/' + volume['DeviceIdentifier']])); result['volume_info_after'] = after
        validate_volume_info(after, volume, device.removeprefix('/dev/') + 's1', mount)
        require(metadata(os.lstat(mount)) == identity, 'Mount directory identity changed')
        active = operations.attachments(image)
        require(len(active) == 1 and backing_device(active[0]) == device, 'Attachment identity changed')
        require(not require_exists or result['marker']['exists'], 'Current Documents marker is missing; persistence is unverified')
        require(not result['marker']['exists'] or result['marker']['content_matches'], 'Existing marker bytes differ from intent')
        result['passed'] = True
    except BaseException as error:
        result['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        cleanup_errors = []
        try:
            if attach_attempted:
                active = operations.attachments(image)
                if active:
                    require(len(active) == 1, 'Ambiguous failed attach cleanup')
                    active_device = backing_device(active[0])
                    require(device is None or active_device == device, 'Cleanup backing device identity changed')
                    device = active_device
                    operations.run(['/usr/bin/hdiutil', 'detach', device])
                require(not operations.attachments(image), 'Image still attached after detach')
            result['remaining_task8_attachments'] = operations.task8_attachments()
            require(not result['remaining_task8_attachments'], 'Task8 attachment remains')
        except BaseException as error: cleanup_errors.append('detach: ' + repr(error))
        # Never remove paths inside a volume whose detach did not succeed.
        if not cleanup_errors and base is not None:
            try:
                for child in base.iterdir(): child.rmdir()
                base.rmdir()
            except BaseException as error: cleanup_errors.append('mount directory: ' + repr(error))
        if initial is not None:
            try:
                final, _ = observe_file(image); result['after'] = final
                require(final == initial, 'Image complete SHA or identity changed across readonly inspection')
            except BaseException as error: cleanup_errors.append('image recheck: ' + repr(error))
        if cleanup_errors: result.update(passed=False, cleanup_errors=cleanup_errors)
    require(result['passed'], 'Image inspection failed: ' + str(image))
    return result


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--marker-evidence-path', help='Optional E/*-marker-v2-create.json for current Disk/UserData')
    args = parser.parse_args(arguments)
    require(re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', args.label) and len(args.label) <= 100, 'Invalid fresh evidence label')
    output_path = E / (args.label + '-marker-images-diagnosis.json')
    record = {'schemaVersion': 1, 'passed': False, 'label': args.label, 'vm': str(VM), 'transaction_id': TX,
              'scope': 'Offline readonly archive Data marker observations; optional current Disk UserData persistence observation. No missing-marker cause determination.',
              'commands': [], 'images': [], 'input_sha256': {}}
    frozen, lock, locked = {}, None, False
    with exclusive_output(output_path) as output:
        try:
            require(os.geteuid() == 0, 'Run as root only after formal VM stop')
            no_symlink_directory(VM)
            lock = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
            require(metadata(os.fstat(lock)) == metadata(os.lstat(VM)), 'VM directory lock identity differs')
            operations = Operations(record); operations.guard()
            def load(path, raw=False):
                return load_frozen(path, frozen, record['input_sha256'], raw=raw)
            journal = load(E / 'kernel-v9-rollback-a-committed-journal.json')
            before = load(E / 'kernel-v9-rollback-a-before.json')
            readback = load(E / 'kernel-v9-rollback-a-readback.json')
            proof = load(E / 'kernel-v9-rollback-a-committed-installed-component-proof.json')
            publication = load(E / 'kernel-v9-rollback-a-committed-component-receipts.json')
            report_path = E / 'kernel-v9-rollback-a-committed-report.json'; load(report_path)
            archive = VM / '.firmware-history' / TX; no_symlink_directory(archive)
            for name in ('journal.json', 'installed-component-proof.json', 'component-receipts.json', 'report.json'):
                path = archive / name; load(path)
                require(frozen[path][1] == frozen[E / ('kernel-v9-rollback-a-committed-' + name)][1], 'Archive differs from frozen committed evidence: ' + name)
            require(journal.get('id') == TX and journal.get('version') == 4 and journal.get('phase') == 'committed'
                    and journal.get('kernelOnly') is True and os.path.realpath(journal.get('vmPath', '')) == str(VM), 'Wrong R_A committed schema4 journal')
            disk = journal['kernelDisk']; require(disk.get('direction') == 'forward' and disk.get('pending') is False
                    and type(disk.get('cursor')) is int and disk['cursor'] == len(disk.get('offsets', [])) == 49
                    and disk.get('originalSHA256') == ORIGINAL_SHA and disk.get('candidateSHA256') == CANDIDATE_SHA
                    and disk.get('size') == 68719476736, 'R_A disk publication state differs')
            require(before.get('passed') is True and before.get('vm') == str(VM) and set(before['files']) == FILES
                    and before['files']['Disk.img']['sha256'] == ORIGINAL_SHA, 'R_A source-before differs')
            require(all(before['files']['Disk.img']['metadata'][key] == disk['identity'][field]
                        for key, field in [('st_dev', 'diskDevice'), ('st_ino', 'diskInode')])
                    and before['files']['Disk.img']['metadata']['st_size'] == disk['size'], 'R_A source disk identity differs')
            require(readback.get('passed') is True and readback.get('transaction_id') == TX and readback.get('journal_version') == 4
                    and readback.get('pending') is False and readback.get('remaining_attachments') == []
                    and readback['files']['Disk.img']['sha256'] == readback.get('disk_sha256_after_readonly') == CANDIDATE_SHA, 'R_A actual readback differs')
            require(journal['rollbackSelection']['targetTransactionID'] == proof['targetTransactionID'] == TARGET_TX
                    and proof['transactionID'] == publication['transactionID'] == TX and proof['imageSHA256'] == CANDIDATE_SHA
                    and readback['proof'] == proof and readback['receipt'] == publication['installed'], 'R_A proof/publication/readback chain differs')
            require(sha(frozen[E / 'kernel-v9-rollback-a-committed-component-receipts.json'][1]) == journal['componentReceiptsSHA256']
                    and sha(frozen[E / 'kernel-v9-rollback-a-committed-installed-component-proof.json'][1]) == publication['originProofSHA256']
                    and sha(frozen[report_path][1]) == journal['reportSHA256'], 'R_A committed evidence digest chain differs')
            old = load(E / 'kernel-v9-plan-b-resumed-marker-create.json')
            intent = load(E / 'kernel-v9-plan-b-resumed-marker-intent.json')
            marker, content = validate_marker(old, intent)
            record['old_marker'] = {'path': marker['path'], 'size': len(content), 'sha256': sha(content)}
            for name, digest in [('kernel-disk-original.img', ORIGINAL_SHA), ('kernel-disk-candidate.img', CANDIDATE_SHA)]:
                inspect_image(operations, archive / name, 'Data', 'tmp/task8-kernel-rollback-' + OLD_UUID, content, digest, disk['size'])
            if args.marker_evidence_path:
                path = Path(args.marker_evidence_path)
                require(path.is_absolute() and path.parent == E and re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*-marker-v2-create.json', path.name), 'Optional marker evidence must be a legal E v2 create file')
                current = load(path); label = current.get('evidence_label')
                require(path.name == label + '-marker-v2-create.json', 'Optional marker label differs')
                require(isinstance(current.get('boot_label'), str) and re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', current['boot_label'])
                        and len(current['boot_label']) <= 80, 'Unsafe v2 boot evidence label')
                current_intent = load(E / (label + '-marker-v2-intent.json'))
                marker, content = validate_marker(current, current_intent, documents=True)
                boot_path = E / (current['boot_label'] + '-boot-watch.json'); boot = load(boot_path)
                require(current.get('source_boot_evidence') == str(boot_path) and current.get('source_boot_sha256') == frozen[boot_path][0]['sha256']
                        and boot.get('passed') is True and boot.get('target') == current['target'] and boot.get('expected') == current['expected'], 'V2 source boot differs')
                expected = current['expected']; require(expected.get('transaction_id') == TX, 'Optional current marker must be from R_A')
                require(expected.get('binding') == {'bundle': '2.6.20261016-local', 'kernel': '2.6.20261021-local'}
                        and expected.get('payload_sha256') == proof['payloadSHA256'], 'Optional current marker installed expectations differ')
                for name, key in [('launchpad.json', 'binding_sha256'), ('.firmware-component-receipts.json', 'receipt_sha256'), ('.firmware-desired-plan.json', 'desired_sha256')]:
                    load(VM / name); require(frozen[VM / name][0]['sha256'] == expected[key], 'Current metadata differs from v2 marker: ' + name)
                require(frozen[VM / '.firmware-component-receipts.json'][1] == frozen[E / 'kernel-v9-rollback-a-committed-component-receipts.json'][1]
                        and decode_json(frozen[VM / 'launchpad.json'][1]) == expected['binding']
                        and expected['desired_sha256'] == journal['rollbackSelection']['liveDesiredSHA256'], 'Optional current publication/binding/live desired differs')
                config_raw = load(VM / 'config.plist', raw=True)
                identity = current['vm_identity']; require(identity.get('vm_directory') == str(VM) and identity.get('config_sha256') == sha(config_raw)
                        and identity.get('machine_identifier_sha256') == sha(plistlib.loads(config_raw)['machineIdentifier'])
                        and identity.get('generation_id') == publication['installed']['generationID'], 'Optional current VM identity differs')
                record['current_documents_marker'] = {'evidence_path': str(path), 'path': marker['path'], 'size': len(content), 'sha256': sha(content)}
                inspect_image(operations, VM / 'Disk.img', 'UserData', 'Documents/task8-kernel-rollback-' + marker['uuid'], content,
                              expected_size=disk['size'], expected_identity=before['files']['Disk.img']['metadata'], require_exists=True)
            for path, (info, raw) in frozen.items():
                after, actual = observe_file(path, 16 << 20)
                require(after == info and actual == raw, 'Input changed during observation: ' + str(path))
            operations.guard(); record['passed'] = True
        except BaseException as error:
            record['error'] = type(error).__name__ + ': ' + str(error)
        finally:
            if locked:
                try:
                    record['final_pending'] = pending(); record['final_task8_attachments'] = operations.task8_attachments()
                    require(not record['final_pending'] and not record['final_task8_attachments'], 'Final pending transaction or attachment remains')
                except BaseException as error: record.update(passed=False, final_check_error=repr(error))
            if lock is not None: os.close(lock)
            output.write((json.dumps(record, indent=2, default=str) + '\n').encode()); output.flush(); os.fsync(output.fileno())
    print(json.dumps({'passed': record['passed'], 'output': str(output_path), 'images': len(record['images']), 'error': record.get('error')}), flush=True)
    return 0 if record['passed'] else 1


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    try: sys.exit(main())
    except Exception as error:
        print(type(error).__name__ + ': ' + str(error), file=sys.stderr); sys.exit(1)

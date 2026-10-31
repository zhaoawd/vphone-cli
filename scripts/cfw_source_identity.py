"""Explicit per-source continuity for historical generation observations.

Historical observations contain device/inode/size/hash, not mtime or ctime.
They remain unchanged. Current metadata is recorded separately, and no
filesystem-wide alias or source/Undo authority is inferred from this record.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

from cfw_reboot_identity import _volume_uuid

REGISTRATION = '.cfw-reboot-source-identity.json'
META = ('dev', 'ino', 'size', 'mtime_ns', 'ctime_ns', 'mode', 'uid', 'gid', 'nlink')


def metadata(info):
    return {name: stat.S_IMODE(info.st_mode) if name == 'mode' else getattr(info, 'st_' + name) for name in META}


def digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def qualification(value):
    if (not isinstance(value, dict) or set(value) != {'manifestSHA256', 'originalName', 'originalTreeSHA256', 'source'}
            or not digest(value['manifestSHA256']) or not digest(value['originalTreeSHA256'])
            or not isinstance(value['originalName'], str) or Path(value['originalName']).name != value['originalName']
            or value['originalName'] in ('', '.', '..')):
        raise ValueError('Complete generation source qualification required')
    source = value['source']
    if (not isinstance(source, dict) or set(source) != {'device', 'inode', 'size', 'sha256'}
            or not digest(source['sha256'])
            or any(type(source[key]) is not int or source[key] < 0 for key in ('device', 'inode', 'size'))):
        raise ValueError('Exact historical source observation required')


class SourceBinding:
    def __init__(self, vm, generation, volume_uuid, members):
        self.vm = Path(vm); self.generation = generation
        if self.vm.resolve(strict=True) != self.vm or not digest(generation):
            raise ValueError('Exact VM and generation required')
        self.volume_uuid = str(uuid.UUID(volume_uuid)); self.members = []; self.verified = False
        if not isinstance(members, list) or not members:
            raise ValueError('Explicit source members required')
        seen_paths = set(); seen_inodes = set()
        for row in members:
            if not isinstance(row, dict) or set(row) != {'path', 'recordedQualification', 'currentQualification', 'currentMetadata'}:
                raise ValueError('Unknown source requalification fields')
            relative = Path(row['path'])
            prefix = ('.firmware-generations', generation, 'originals')
            if (not isinstance(row['path'], str) or relative.is_absolute() or str(relative) != row['path']
                    or '..' in relative.parts or relative.parts[:3] != prefix or len(relative.parts) < 5
                    or row['path'] in seen_paths):
                raise ValueError('Source is outside the exact generation original namespace')
            old = row['recordedQualification']; current = row['currentQualification']
            qualification(old); qualification(current)
            normalized = dict(current, source=dict(current['source'], device=old['source']['device']))
            info = row['currentMetadata']
            if (normalized != old or old['source']['device'] == current['source']['device']
                    or relative.parts[3] != current['originalName']
                    or not isinstance(info, dict) or set(info) != set(META)
                    or any(type(info[key]) is not int or info[key] < 0 for key in META)
                    or info['mode'] > 0o7777 or info['nlink'] != 1
                    or (info['dev'], info['ino'], info['size']) != tuple(current['source'][key] for key in ('device', 'inode', 'size'))
                    or (info['dev'], info['ino']) in seen_inodes):
                raise ValueError('Only the historical source device number may differ')
            seen_paths.add(row['path']); seen_inodes.add((info['dev'], info['ino']))
            self.members.append(row)

    def _info(self, path):
        path = Path(path)
        if path.resolve(strict=True) != path or self.vm not in path.parents:
            raise ValueError('Linked or escaping generation source')
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_dev != self.vm.stat().st_dev:
            raise ValueError('Source is not a private file on the qualified VM volume')
        return info

    def verify_files(self, plan, volume_uuid):
        from patchers.undo_provenance import qualify_source
        self.verified = False
        if (str(uuid.UUID(volume_uuid)) != self.volume_uuid or plan.context['generationID'] != self.generation
                or plan.context['vmDirectory'] != str(self.vm)):
            raise ValueError('Source requalification differs from the current VM/generation/volume')
        for row in self.members:
            path = self.vm / row['path']; before = self._info(path)
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                if metadata(before) != row['currentMetadata'] or metadata(os.fstat(fd)) != metadata(before):
                    raise ValueError('Source metadata differs before complete readback')
                if qualify_source(plan, path) != row['currentQualification']:
                    raise ValueError('Complete source manifest/tree/hash differs')
                if metadata(os.fstat(fd)) != metadata(before) or metadata(self._info(path)) != metadata(before):
                    raise ValueError('Source changed during complete qualification')
            finally: os.close(fd)
        self.verified = True

    def matches(self, path, actual, recorded):
        if not self.verified: return False
        try:
            name = str(Path(path).relative_to(self.vm)); info = metadata(self._info(Path(path)))
        except (OSError, ValueError): return False
        return any(row['path'] == name and row['recordedQualification'] == recorded
                   and row['currentQualification'] == actual and row['currentMetadata'] == info for row in self.members)


def decode(record, vm, generation):
    if (not isinstance(record, dict) or set(record) != {'schemaVersion', 'kind', 'vmDirectory', 'generationID',
            'volumeUUID', 'approvedPlanSHA256', 'members'} or type(record['schemaVersion']) is not int
            or record['schemaVersion'] != 1 or record['kind'] != 'explicit-generation-source-requalification'
            or record['vmDirectory'] != str(vm) or record['generationID'] != generation
            or not digest(record['approvedPlanSHA256'])):
        raise ValueError('Source registration differs from the approved scope')
    return SourceBinding(vm, generation, record['volumeUUID'], record['members'])


def registered_bytes(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != 0 or stat.S_IMODE(before.st_mode) != 0o444
                or before.st_nlink != 1 or not 0 <= before.st_size <= 1 << 20):
            raise ValueError('Source registration must be a root-owned 0444 private file')
        raw = os.read(fd, (1 << 20) + 1)
        if (len(raw) != before.st_size or metadata(os.fstat(fd)) != metadata(before)
                or metadata(path.lstat()) != metadata(before)):
            raise ValueError('Source registration changed during read')
        return raw
    finally: os.close(fd)


def binding_for(plan):
    vm = Path(plan.context['vmDirectory']); path = vm / REGISTRATION
    if not os.path.lexists(path): return None
    binding = decode(json.loads(registered_bytes(path)), vm, plan.context['generationID'])
    if _volume_uuid(vm) != binding.volume_uuid:
        raise ValueError('Registered generation source volume differs')
    # The root writer fully verified both manifest trees and source hashes.
    # Every actual comparison below still receives a freshly qualified source.
    binding.verified = True
    return binding


def matches_qualified_source(plan, path, actual, recorded):
    if actual == recorded: return True
    qualification(actual); qualification(recorded)
    normalized = dict(actual, source=dict(actual['source'], device=recorded['source']['device']))
    if normalized != recorded or actual['source']['device'] == recorded['source']['device']:
        return False
    binding = binding_for(plan)
    return binding is not None and binding.matches(Path(path), actual, recorded)


def register_sources(plan, approved_plan_sha256, members):
    import vm_lock
    if os.geteuid() != 0: raise ValueError('Explicit root source registration required')
    vm = Path(plan.context['vmDirectory']); vm_lock.check_inherited(vm)
    record = dict(schemaVersion=1, kind='explicit-generation-source-requalification', vmDirectory=str(vm),
        generationID=plan.context['generationID'], volumeUUID=_volume_uuid(vm),
        approvedPlanSHA256=approved_plan_sha256, members=members)
    binding = decode(record, vm, plan.context['generationID']); binding.verify_files(plan, record['volumeUUID'])
    raw = (json.dumps(record, sort_keys=True, separators=(',', ':')) + '\n').encode()
    path = vm / REGISTRATION
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        if os.fstat(fd).st_uid != 0: raise ValueError('Source registration is not root-owned')
        view = memoryview(raw)
        while view:
            count = os.write(fd, view)
            if count <= 0: raise OSError('Short source registration write')
            view = view[count:]
        os.fsync(fd); os.fchmod(fd, 0o444); os.fsync(fd)
    finally: os.close(fd)
    directory = os.open(vm, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: os.fsync(directory)
    finally: os.close(directory)
    if registered_bytes(path) != raw: raise ValueError('Source registration readback differs')
    return hashlib.sha256(raw).hexdigest()

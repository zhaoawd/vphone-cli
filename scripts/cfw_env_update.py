#!/usr/bin/env python3
"""Offline guest-environment eligibility and replacement (T16).

The library list comes from guest_environment.json beside this script; the
API daemon's list is checked against the same file by the tests. Expected
contents are the signed candidates in the guest component stage
(.build/guest-components-v2/stage, built by `make guest_components_build`),
verified against that stage's manifest.json.

Classification of a stopped VM's system volume:

  already_current          every local library and load path is present and
                           every library equals its candidate
  offline_update           the same, but at least one library differs; only
                           those libraries would be replaced
  full_migration_required  a library, the /vh alias, the launchd /vh load
                           command or the CFW install marker is missing, the
                           bootstrap is classic (/b) or unknown, or a classic
                           variant record names a v2 disk; a stopped-VM file
                           replacement cannot supply any of these
  not_applicable           the recorded variant installs no CFW (less)

libmisfix.dylib (upstream 2.2.3) is reported as upstream_only; it never fails
the check and is never replaced (T18).

Commands:
  check-vm VM_DIR [--components DIR] [--report FILE [--owner UID[:GID]]]
      Read-only. Holds the VM directory lock (flock, no record written) and a
      read-only descriptor on Disk.img, attaches it read-only, mounts the
      System volume read-only outside the bundle, prints a JSON report.
      Exit 0 classified; 2 input error; 4 VM busy; 5 disk access failed (the
      message names the stage: attach, locate, mount, read, unmount, detach
      or verify, and the next step). Each disk tool runs under a per-stage
      limit (STAGE_TIMEOUTS). With --report (cfw_install_host.sh
      --check-environment, which vphone-cli runs as root through sudo or
      --root-popup), the result, including a failure and its exit code, is
      written to FILE instead of stdout: a new file in a directory that UID
      (the invoker) or, without --owner, this process owns and that group and
      others cannot write; the file is mode 0600 and owned by UID[:GID].
  apply --device DEV --mount DIR --report FILE [--components DIR] VM_DIR
      Run by cfw_install_host.sh --update-environment on the staged copy of
      Disk.img (T15 transaction). Mounts DEV read-write at DIR, re-checks,
      replaces only differing libraries. Exit 0 replaced; 3 refused; 1 failed.
  identity --compare REPORT VM_DIR
      After publication: compare the bundle identity files with the digests
      apply recorded. Exit 0 unchanged; 3 changed.
"""
import argparse
import datetime
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import cfw_disk_txn  # noqa: E402

MANIFEST = SCRIPT_DIR / 'guest_environment.json'
SCHEMA = 'vphone.guest-environment-eligibility/1'
RESULT_SCHEMA = 'vphone.guest-environment-check-result/1'
DISK = 'Disk.img'

HDIUTIL = '/usr/bin/hdiutil'
DISKUTIL = '/usr/sbin/diskutil'
MOUNT_APFS = '/sbin/mount_apfs'
UMOUNT = '/sbin/umount'

# Seconds per disk-tool stage. Basis (research/t16_offline_update_eligibility_
# 2026-10-01.md, follow-up section): on this host (macOS 27, 2026-10-01) a
# normal user attached, located, mounted read-only, unmounted and detached
# disposable raw APFS images of 64 MiB and 2 GiB in at most 0.29 s per step
# (5 runs each; mount at most 0.007 s). The previous single limit was 180 s,
# and an unprivileged mount of a real VM System volume used all of it without
# returning. 30 s is about 100 times the slowest measured step and ends a
# blocked step within half a minute.
STAGE_TIMEOUTS = {'attach': 30, 'locate': 30, 'mount': 30, 'unmount': 30, 'detach': 30}

LC_REQ_DYLD = 0x80000000
DYLIB_COMMANDS = {0xC, 0x18 | LC_REQ_DYLD, 0x1F | LC_REQ_DYLD, 0x20, 0x23 | LC_REQ_DYLD}
LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF


class Refused(Exception):
    """A precondition failed; nothing was written."""


class Busy(Refused):
    pass


class DiskAccess(Exception):
    """A disk step failed; stage is attach, locate, mount, read, unmount, detach or verify."""

    def __init__(self, stage, message, advice=None):
        super().__init__(message)
        self.stage = stage
        self.advice = advice or stage_advice(stage)


def stage_advice(stage):
    if stage == 'mount' and os.geteuid() != 0:
        return ('this user could not mount the System volume read-only; run the check as root: '
                'vphone-cli cfw update-environment <name> --check (sudo), or add --root-popup for the macOS '
                'authentication dialog')
    return {
        'attach': 'check that Disk.img is a raw disk image that no other process has attached (hdiutil info), '
                  'then rerun the check',
        'locate': 'the attached image has no APFS volume named System; check that this VM was restored',
        'mount': 'check `mount` and `hdiutil info` for a leftover of this check and the system log '
                 '(log show --last 5m --predicate \'process == "mount_apfs"\'), then rerun the check',
        'read': 'a file on the read-only System volume could not be read; run the check as root '
                '(vphone-cli cfw update-environment <name> --check, or with --root-popup) or inspect the volume',
        'unmount': "unmount the check's mountpoint (umount, then diskutil unmount force) before starting the VM",
        'detach': 'detach the image (hdiutil info; hdiutil detach <disk>, then -force) before starting the VM',
        'verify': 'Disk.img changed while it was attached read-only; stop whatever wrote it and rerun the check',
    }.get(stage)


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def sha256_path(path):
    digest = hashlib.sha256()
    with open(path, 'rb', opener=lambda name, flags: os.open(name, flags | os.O_NOFOLLOW)) as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def load_manifest(path=MANIFEST):
    manifest = json.loads(Path(path).read_text())
    if manifest.get('schema_version') != 1 or not manifest.get('libraries'):
        raise Refused(f'unsupported environment manifest {path}')
    return manifest


# MARK: - Mach-O load commands

def macho_commands(data):
    """(cmd, payload) for every load command of every slice."""
    def slice_commands(offset):
        magic, = struct.unpack_from('<I', data, offset)
        if magic != MH_MAGIC_64:
            raise ValueError('not a 64-bit Mach-O')
        ncmds, sizeofcmds = struct.unpack_from('<II', data, offset + 16)
        position, end = offset + 32, offset + 32 + sizeofcmds
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', data, position)
            if size < 8 or position + size > end:
                raise ValueError('malformed load command')
            yield cmd, data[position:position + size]
            position += size

    if len(data) < 32:
        raise ValueError('file too small for a Mach-O header')
    magic_be, = struct.unpack_from('>I', data, 0)
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        count, = struct.unpack_from('>I', data, 4)
        entry = 20 if magic_be == FAT_MAGIC else 32
        for index in range(count):
            base = 8 + index * entry
            offset = struct.unpack_from('>I' if magic_be == FAT_MAGIC else '>Q', data, base + 8)[0]
            yield from slice_commands(offset)
    else:
        yield from slice_commands(0)


def dylib_loads(path):
    names = []
    for cmd, payload in macho_commands(Path(path).read_bytes()):
        if cmd in DYLIB_COMMANDS:
            offset, = struct.unpack_from('<I', payload, 8)
            names.append(payload[offset:].split(b'\0', 1)[0].decode('utf-8', 'replace'))
    return names


def has_code_signature(path):
    return any(cmd == LC_CODE_SIGNATURE for cmd, _ in macho_commands(Path(path).read_bytes()))


# MARK: - Inputs

def candidates(stage, manifest):
    """name -> {source, sha256}; Refused when the stage cannot be trusted."""
    stage = Path(stage)
    record = stage / 'manifest.json'
    if not stage.is_dir() or stage.is_symlink() or not record.is_file():
        raise Refused(f'candidate stage {stage} has no manifest.json; run make guest_components_build '
                      'or pass --components')
    recorded = json.loads(record.read_text()).get('files_sha256', {})
    result = {}
    for entry in manifest['libraries']:
        path = stage / entry['stage']
        if path.is_symlink() or not path.is_file():
            raise Refused(f'candidate {path} is missing or not a regular file')
        digest = sha256_path(path)
        if recorded.get(entry['stage']) != digest:
            raise Refused(f'candidate {path} differs from {record} '
                          f'({recorded.get(entry["stage"])} recorded, {digest} found)')
        try:
            signed = has_code_signature(path)
        except (ValueError, struct.error) as error:
            raise Refused(f'candidate {path} is not a Mach-O: {error}')
        if not signed:
            raise Refused(f'candidate {path} has no code signature')
        result[entry['name']] = {'source': str(path), 'sha256': digest}
    return result


def variant_records(vm):
    records = {'restore_info': None, 'checkpoint': None}
    for key, relative in (('restore_info', 'restore-info.json'), ('checkpoint', '.create-checkpoint/checkpoint.json')):
        try:
            value = json.loads((Path(vm) / relative).read_text()).get('variant')
        except (OSError, ValueError, AttributeError):
            continue
        records[key] = value if isinstance(value, str) else None
    return records


def bundle_identity(vm):
    """SHA-256 of the files that hold the VM configuration, identity and variant."""
    vm = Path(vm)
    names = ['config.plist', 'restore-info.json', 'udid-prediction.txt', '.create-checkpoint/checkpoint.json']
    try:
        config = plistlib.loads((vm / 'config.plist').read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        config = {}
    for key in ('nvramStorage', 'sepStorage'):
        value = config.get(key)
        if isinstance(value, str) and value and not os.path.isabs(value) and '..' not in Path(value).parts:
            names.append(value)
    names += sorted(path.name for path in vm.glob('*.shsh'))
    identity = {}
    for name in dict.fromkeys(names):
        path = vm / name
        if path.is_file() and not path.is_symlink():
            identity[name] = sha256_path(path)
    return identity


# MARK: - Classification

def assess(root, vm, components, manifest=None):
    """Classify the mounted system volume at root. Reads only."""
    manifest = manifest or load_manifest()
    root, vm = Path(root), Path(vm)
    reasons, notes = [], []
    records = variant_records(vm)
    recorded = {value for value in records.values() if value}
    report = {
        'schema': SCHEMA, 'checked_at': now(), 'vm': str(vm),
        'manifest': {'path': str(MANIFEST), 'sha256': sha256_path(MANIFEST)},
        'variant_records': records, 'classification': None, 'reasons': reasons, 'notes': notes,
        'replace': [], 'libraries': [], 'load_paths': [],
    }
    try:
        expected = candidates(components, manifest)
        report['candidates'] = {'stage': str(components), 'available': True}
    except Refused as error:
        expected = None
        report['candidates'] = {'stage': str(components), 'available': False, 'error': str(error)}

    # Libraries
    missing = []
    for entry in manifest['libraries']:
        path = root / entry['guest']
        row = {'name': entry['name'], 'scope': 'local', 'guest_path': '/' + entry['guest'],
               'loaded_by': entry['loaded_by'], 'present': False, 'actual_sha256': None,
               'expected_sha256': expected[entry['name']]['sha256'] if expected else None,
               'expected_source': expected[entry['name']]['source'] if expected else None}
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            row['state'] = 'missing'
            missing.append(f'{row["guest_path"]} is missing')
        else:
            row['present'] = True
            if not stat.S_ISREG(info.st_mode):
                row['state'] = 'not_regular_file'
                missing.append(f'{row["guest_path"]} is not a regular file')
            else:
                row['actual_sha256'] = sha256_path(path)
                row['mode'] = f'{stat.S_IMODE(info.st_mode):04o}'
                if row['expected_sha256'] is None:
                    row['state'] = 'present'
                else:
                    row['state'] = 'current' if row['actual_sha256'] == row['expected_sha256'] else 'differs'
        report['libraries'].append(row)
    for entry in manifest.get('upstream_only', []):
        path = root / entry['guest']
        present = os.path.lexists(path)
        row = {'name': entry['name'], 'scope': 'upstream_only', 'task': entry['task'], 'managed': False,
               'guest_path': '/' + entry['guest'], 'present': present,
               'actual_sha256': sha256_path(path) if present and path.is_file() and not path.is_symlink() else None,
               'state': 'upstream_only_present_not_managed' if present else 'upstream_only_absent'}
        report['libraries'].append(row)
        notes.append(f'{entry["name"]}: upstream 2.2.3 environment library, not built or installed locally '
                     f'({entry["task"]}); {"present on the disk and left unchanged" if present else "absent"}; '
                     'not part of this check or replacement')

    # Load paths and bootstrap
    marker = root / manifest['install_marker']
    marker_ok = marker.is_file() and not marker.is_symlink()
    report['load_paths'].append({'id': 'cfw_install_marker', 'path': '/' + manifest['install_marker'],
                                 'expected': 'regular file written by the first CFW install', 'ok': marker_ok})
    alias = manifest['load_alias']
    alias_path = root / alias['path']
    actual_alias = os.readlink(alias_path) if alias_path.is_symlink() else (
        'not a symbolic link' if os.path.lexists(alias_path) else None)
    alias_ok = actual_alias == alias['target']
    report['load_paths'].append({'id': 'launchd_hook_alias', 'path': '/' + alias['path'],
                                 'expected': f'symbolic link to {alias["target"]}', 'actual': actual_alias,
                                 'ok': alias_ok})
    launchd = root / manifest['launchd']
    try:
        loads = dylib_loads(launchd)
        launchd_error = None
    except (OSError, ValueError, struct.error) as error:
        loads, launchd_error = [], str(error)
    custom = [name for name in loads if not name.startswith(('/usr/lib/', '/System/'))]
    command_ok = alias['load_command'] in custom
    report['load_paths'].append({'id': 'launchd_load_command', 'path': '/' + manifest['launchd'],
                                 'expected': f'load command for {alias["load_command"]}',
                                 'actual': custom if launchd_error is None else launchd_error, 'ok': command_ok})
    classic = manifest['classic_bootstrap']
    classic_seen = classic['load_command'] in custom or os.path.lexists(root / classic['path'])
    v2_seen = alias['load_command'] in custom or os.path.lexists(alias_path)
    unknown = [name for name in custom if name not in (alias['load_command'], classic['load_command'])]
    if launchd_error is not None or unknown or (classic_seen and v2_seen):
        kind = 'unknown'
    elif classic_seen:
        kind = 'classic'
    elif v2_seen:
        kind = 'v2'
    else:
        kind = 'none'
    report['bootstrap'] = {'kind': kind, 'launchd_custom_loads': custom,
                           'classic_alias_present': os.path.lexists(root / classic['path']),
                           'v2_alias_present': os.path.lexists(alias_path)}

    # Reasons, in priority order of the classification.
    if not marker_ok:
        reasons.append(f'{"/" + manifest["install_marker"]} is missing: the system volume has no completed CFW install')
    if kind == 'unknown':
        detail = launchd_error or ', '.join(unknown) or 'both /b and /vh are present'
        reasons.append(f'unknown bootstrap: launchd {detail}')
    elif kind == 'classic':
        reasons.append(f'classic bootstrap: launchd loads {classic["load_command"]} (BaseBin launchdhook); '
                       f'the local environment loads launchdhook-vphone through {alias["load_command"]}')
    elif kind == 'none':
        reasons.append('launchd has no environment load command (classic install without the v2 environment)')
    if kind == 'v2':
        classic_records = sorted(recorded & set(manifest['classic_variants']))
        if classic_records:
            reasons.append(f'recorded variant {", ".join(classic_records)} is a classic install; '
                           'the v2 environment on the disk does not match it')
    if kind in ('v2', 'unknown'):
        if not alias_ok:
            reasons.append(f'/{alias["path"]} is {actual_alias or "missing"}, expected a link to {alias["target"]}')
        if not command_ok:
            reasons.append(f'launchd has no load command for {alias["load_command"]}')
    reasons.extend(missing)

    if recorded & set(manifest['not_applicable_variants']):
        report['classification'] = 'not_applicable'
        report['reasons'] = [f'recorded variant {", ".join(sorted(recorded))} installs no CFW']
        return report
    if reasons:
        report['classification'] = 'full_migration_required'
        report['migration'] = ('A stopped-VM replacement only swaps libraries that already exist. Create a new VM '
                               'whose CFW install places every environment library in /usr/lib, the /vh alias and '
                               'the launchd /vh load command, and validate it as a separate copy; this VM is left '
                               'unchanged.')
        return report
    if expected is None:
        raise Refused(report['candidates']['error'])
    changed = [row['name'] for row in report['libraries'] if row['scope'] == 'local' and row['state'] == 'differs']
    report['replace'] = changed
    report['classification'] = 'offline_update' if changed else 'already_current'
    report['activation'] = activation(changed, manifest)
    return report


def activation(changed, manifest):
    """What loads the new files. Nothing is restarted by this tool."""
    loaded_by = {entry['name']: entry['loaded_by'] for entry in manifest['libraries']}
    reasons = [f'{name}: loaded by {loaded_by[name]}' for name in changed]
    return {
        'automatic_restart': False,
        'respring_requested': False,
        'next_step': 'start the VM; the replacement is written while it is stopped, so every process that maps '
                     'these libraries is started after it (inference; not verified on a guest)'
                     if changed else 'none',
        'respring': 'not requested: SpringBoard starts during the next boot; a running guest is not touched '
                    '(process activation is T17)',
        'reasons': reasons,
    }


# MARK: - Disk access (replaced by the test harness)

def run_tool(arguments, stage):
    limit = STAGE_TIMEOUTS[stage]
    command = ' '.join(map(str, arguments))
    try:
        result = subprocess.run(arguments, capture_output=True, timeout=limit)
    except subprocess.TimeoutExpired:
        raise DiskAccess(stage, f'{command} timed out after {limit} s and was stopped')
    except OSError as error:
        raise DiskAccess(stage, f'{arguments[0]}: {error}')
    if result.returncode != 0:
        raise DiskAccess(stage, f'{command} exited with {result.returncode}: '
                                f'{result.stderr.decode(errors="replace").strip()}')
    return result.stdout


def attach_readonly(image):
    output = run_tool([HDIUTIL, 'attach', '-readonly', '-nomount', '-plist',
                       '-imagekey', 'diskimage-class=CRawDiskImage', str(image)], 'attach')
    entities = plistlib.loads(output).get('system-entities', [])
    devices = [entry.get('dev-entry', '') for entry in entities]
    bases = {device for device in devices if device.startswith('/dev/disk') and device[9:].isdigit()}
    physical = {entry.get('dev-entry') for entry in entities if entry.get('content-hint') in
                ('GUID_partition_scheme', 'FDisk_partition_scheme', 'Apple_partition_scheme')}
    if physical & bases:
        bases &= physical
    if len(bases) != 1:
        for device in bases:
            try:
                subprocess.run([HDIUTIL, 'detach', device], capture_output=True, timeout=STAGE_TIMEOUTS['detach'])
            except subprocess.TimeoutExpired:
                print(f'[!] stage detach: hdiutil detach {device} timed out; detach it manually', file=sys.stderr)
        raise DiskAccess('attach', f'no unique base disk in hdiutil output: {sorted(bases)}')
    return bases.pop()


def system_volume(base):
    info = plistlib.loads(run_tool([DISKUTIL, 'info', '-plist', f'{base}s1'], 'locate'))
    container = info.get('APFSContainerReference')
    if not container:
        raise DiskAccess('locate', f'{base}s1 is not an APFS physical store')
    listing = plistlib.loads(run_tool([DISKUTIL, 'apfs', 'list', '-plist', container], 'locate'))
    for item in listing.get('Containers', []):
        for volume in item.get('Volumes', []):
            if volume.get('Name') == 'System' or 'System' in volume.get('Roles', []):
                return '/dev/' + volume['DeviceIdentifier']
    raise DiskAccess('locate', f'no System volume in container {container}')


def mount_volume(device, mountpoint, readonly=False):
    options = 'rdonly,nobrowse' if readonly else 'rw,nobrowse'
    run_tool([MOUNT_APFS, '-o', options, device, str(mountpoint)], 'mount')


def unmount(mountpoint):
    try:
        run_tool([UMOUNT, str(mountpoint)], 'unmount')
    except DiskAccess:
        run_tool([UMOUNT, '-f', str(mountpoint)], 'unmount')


def detach(base):
    try:
        run_tool([HDIUTIL, 'detach', base], 'detach')
    except DiskAccess:
        run_tool([HDIUTIL, 'detach', '-force', base], 'detach')


# MARK: - check-vm

def check_vm(vm, components):
    vm = Path(vm).resolve(strict=True)
    manifest = load_manifest()
    lock = os.open(vm, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                raise Busy(f'VM lock held on {vm}: the VM is running or another operation owns it')
            raise
        disk = vm / DISK
        named = os.lstat(disk)
        if not stat.S_ISREG(named.st_mode):
            raise Refused(f'{disk} is not a regular file')
        fd = os.open(disk, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            held = os.fstat(fd)
            before = cfw_disk_txn.identity(held)
            before['sample'] = cfw_disk_txn.sample_digest(fd, held.st_size)
            holders = cfw_disk_txn.holders(disk, os.getpid())
            if holders:
                raise Busy(f'{disk} is open in process(es) {", ".join(map(str, holders))}; stop the VM first')
            records = variant_records(vm)
            if {value for value in records.values() if value} & set(manifest['not_applicable_variants']):
                report = assess_without_disk(vm, components, manifest)
            else:
                report = assess_disk(disk, fd, vm, components, manifest)
            report['identity'] = bundle_identity(vm)
            after = os.fstat(fd)
            sample = cfw_disk_txn.sample_digest(fd, after.st_size)
            unchanged = ((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) ==
                         (before['dev'], before['ino'], before['size'], before['mtime_ns'])
                         and sample == before['sample'])
            report['disk'] = {'path': str(disk), 'inode': before['ino'], 'size': before['size'],
                              'mtime_ns': before['mtime_ns'], 'sample': before['sample'], 'attach': 'read-only',
                              'unchanged': unchanged}
            if not unchanged:
                raise DiskAccess('verify', f'{disk} changed during the read-only check')
            return report
        finally:
            os.close(fd)
    finally:
        os.close(lock)


def assess_without_disk(vm, components, manifest):
    with tempfile.TemporaryDirectory(prefix='vphone-env-empty.') as empty:
        report = assess(empty, vm, components, manifest)
    report['disk_read'] = False
    return report


def announce_mount(device, mountpoint):
    limit = STAGE_TIMEOUTS['mount']
    if os.geteuid() == 0:
        print(f'[*] mount: {device} read-only at {mountpoint} (limit {limit} s)', file=sys.stderr)
        return
    print(f'[*] mount: {device} read-only at {mountpoint} as uid {os.geteuid()} (limit {limit} s). If this user '
          'may not mount it, the check stops at stage mount; run it as root with '
          'vphone-cli cfw update-environment <name> --check (sudo) or add --root-popup', file=sys.stderr)


def release(base, mountpoint, mounted, strict):
    """Unmount, remove the mountpoint, detach. strict: raise the first failure;
    otherwise (an earlier error is propagating) only report it."""
    failure = None
    if mounted:
        try:
            unmount(mountpoint)
        except DiskAccess as error:
            failure = error
            print(f'[!] stage unmount: {error}; mountpoint {mountpoint} retained', file=sys.stderr)
    if mountpoint is not None and failure is None:
        try:
            mountpoint.rmdir()
        except OSError as error:
            print(f'[!] mountpoint {mountpoint} retained: {error}', file=sys.stderr)
    try:
        detach(base)
    except DiskAccess as error:
        failure = failure or error
        print(f'[!] stage detach: {error}; {base} may still be attached', file=sys.stderr)
    if strict and failure is not None:
        raise failure


def assess_disk(disk, fd, vm, components, manifest):
    base = attach_readonly(disk)
    mountpoint, mounted = None, False
    try:
        held, named = os.fstat(fd), os.lstat(disk)
        if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
            raise DiskAccess('attach', f'{disk} was replaced while it was attached')
        device = system_volume(base)
        # Outside the bundle: the system temporary directory of this process.
        mountpoint = Path(tempfile.mkdtemp(prefix='vphone-env-check.'))
        announce_mount(device, mountpoint)
        try:
            mount_volume(device, mountpoint, readonly=True)
            mounted = True
        except DiskAccess:
            mounted = os.path.ismount(mountpoint)   # a stopped mount_apfs may have mounted it
            raise
        try:
            report = assess(mountpoint, vm, components, manifest)
        except OSError as error:
            raise DiskAccess('read', f'reading the mounted System volume failed: {error}')
    except BaseException:
        release(base, mountpoint, mounted, strict=False)
        raise
    release(base, mountpoint, mounted, strict=True)
    report['disk_read'] = True
    report['system_volume'] = device
    return report


# MARK: - apply (staged copy, inside the T15 transaction)

def replace_file(source, target):
    """Write source over an existing regular file, keeping its owner and mode."""
    target = Path(target)
    info = os.lstat(target)
    if not stat.S_ISREG(info.st_mode):
        raise Refused(f'{target} is not a regular file')
    temporary = target.parent / f'.{target.name}.vphone-env-{os.getpid()}'
    out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        with open(source, 'rb') as stream:
            for block in iter(lambda: stream.read(1 << 20), b''):
                view = memoryview(block)
                while view:
                    view = view[os.write(out, view):]
        os.fchown(out, info.st_uid, info.st_gid)
        os.fchmod(out, stat.S_IMODE(info.st_mode))
        os.fsync(out)
        os.close(out)
        out = -1
        os.rename(temporary, target)
    except BaseException:
        if out >= 0:
            os.close(out)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def save(path, report):
    temporary = Path(str(path) + '.tmp')
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, path)


def apply_mounted(root, vm, components, report_path, manifest=None):
    manifest = manifest or load_manifest()
    root = Path(root)
    record = {'schema': SCHEMA, 'operation': 'offline_environment_update', 'started_at': now(),
              'vm': str(vm), 'result': 'failed', 'replaced': []}
    try:
        before = assess(root, vm, components, manifest)
    except Refused as error:
        record.update(result='refused', reasons=[str(error)])
        save(report_path, record)
        print(f'[-] environment update refused: {error}', file=sys.stderr)
        return 3
    record['before'] = before
    record['identity_before'] = bundle_identity(vm)
    if before['classification'] != 'offline_update':
        record.update(result='refused', reasons=before['reasons'] or [before['classification']])
        save(report_path, record)
        print(f'[-] environment update refused: {before["classification"]}', file=sys.stderr)
        for reason in before['reasons']:
            print(f'    - {reason}', file=sys.stderr)
        if before.get('migration'):
            print(f'    {before["migration"]}', file=sys.stderr)
        return 3
    rows = {row['name']: row for row in before['libraries']}
    try:
        for name in before['replace']:
            row = rows[name]
            replace_file(row['expected_source'], root / row['guest_path'].lstrip('/'))
            record['replaced'].append(name)
            print(f'  [+] {row["guest_path"]}: {row["actual_sha256"][:16]} -> {row["expected_sha256"][:16]}')
        after = assess(root, vm, components, manifest)
        record['after'] = after
        if after['classification'] != 'already_current':
            raise Refused(f'after replacement the volume is {after["classification"]}: {after["reasons"]}')
        untouched = {row['name']: row['actual_sha256'] for row in before['libraries']
                     if row['name'] not in before['replace']}
        for row in after['libraries']:
            if row['name'] in untouched and row['actual_sha256'] != untouched[row['name']]:
                raise Refused(f'{row["guest_path"]} changed although it was not selected')
    except (Refused, OSError) as error:
        record['error'] = str(error)
        save(report_path, record)
        print(f'[-] environment update failed on the staged copy: {error}; the original Disk.img is not '
              'written and the copy is discarded', file=sys.stderr)
        return 1
    record['result'] = 'replaced'
    record['activation'] = before['activation']
    record['finished_at'] = now()
    save(report_path, record)
    print(f'[*] replaced {len(record["replaced"])} environment librar{"y" if len(record["replaced"]) == 1 else "ies"} '
          f'on the staged copy: {", ".join(record["replaced"])}')
    return 0


def apply(args):
    vm = Path(args.vm).resolve(strict=True)
    mountpoint = Path(args.mount)
    if vm not in mountpoint.resolve().parents:
        raise Refused(f'mountpoint {mountpoint} must be inside {vm}')
    mountpoint.mkdir(mode=0o700, exist_ok=True)
    mount_volume(args.device, mountpoint, readonly=False)
    return apply_mounted(mountpoint, vm, Path(args.components), Path(args.report))


def compare_identity(report_path, vm):
    report = json.loads(Path(report_path).read_text())
    report['identity_after'] = bundle_identity(vm)
    report['identity_unchanged'] = report['identity_after'] == report.get('identity_before')
    save(report_path, report)
    if not report['identity_unchanged']:
        print('[-] VM configuration, identity or variant files changed during the environment update: '
              f'{report.get("identity_before")} -> {report["identity_after"]}', file=sys.stderr)
        return 3
    print(f'[*] configuration, identity and variant files unchanged ({len(report["identity_after"])} files)')
    activation_info = report.get('activation') or {}
    if activation_info.get('reasons'):
        print(f'[*] {activation_info["next_step"]}')
        for reason in activation_info['reasons']:
            print(f'    - {reason}')
        print(f'[*] respring {activation_info["respring"]}')
    return 0


# MARK: - Result file for an elevated check

def parse_owner(text):
    """'UID[:GID]' (decimal) -> (uid, gid or None); None for no owner."""
    if text is None:
        return None
    uid, _, gid = text.partition(':')
    if not uid.isdigit() or (gid and not gid.isdigit()):
        raise Refused(f'--owner {text!r} is not UID[:GID]')
    return int(uid), int(gid) if gid else None


def open_destination(path, owner):
    """(directory descriptor, name) for a new result file.

    The directory is the caller's private directory: owned by the invoker
    (owner) or, without one, by this process; not writable by group or others;
    not a symbolic link. The name must not exist yet. Checked before the disk
    is touched; the file is created later with O_EXCL beneath the same
    descriptor, so a renamed or replaced directory cannot redirect the write.
    """
    path = Path(path)
    if not path.is_absolute() or path.name in ('', '.', '..'):
        raise Refused(f'report path {path} must be an absolute file path')
    expected = owner[0] if owner else os.geteuid()
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(directory)
        if info.st_uid != expected:
            raise Refused(f'report directory {path.parent} has owner uid {info.st_uid}, not the invoker uid {expected}')
        if info.st_mode & 0o022:
            raise Refused(f'report directory {path.parent} is writable by group or others '
                          f'(mode {stat.S_IMODE(info.st_mode):04o})')
        try:
            os.stat(path.name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            return directory, path.name
        raise Refused(f'report path {path} already exists')
    except BaseException:
        os.close(directory)
        raise


def write_result(destination, owner, result):
    directory, name = destination
    data = (json.dumps(result, indent=2, sort_keys=True) + '\n').encode()
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        if owner:
            os.fchown(fd, owner[0], -1 if owner[1] is None else owner[1])
        os.fchmod(fd, 0o600)
        os.fsync(fd)
    finally:
        os.close(fd)


# MARK: - CLI

def default_components():
    return SCRIPT_DIR.parent / load_manifest()['candidate_stage']


def run_check_vm(vm, components):
    """(exit code, report or None, error or None); errors are also printed."""
    try:
        return 0, check_vm(vm, components), None
    except Busy as error:
        print(f'[-] {error}', file=sys.stderr)
        return 4, None, {'kind': 'busy', 'stage': None, 'message': str(error),
                         'advice': 'stop the VM or wait for the other operation, then rerun the check'}
    except DiskAccess as error:
        print(f'[-] disk access failed at stage {error.stage}: {error}', file=sys.stderr)
        if error.advice:
            print(f'    next: {error.advice}', file=sys.stderr)
        return 5, None, {'kind': 'disk_access', 'stage': error.stage, 'message': str(error), 'advice': error.advice}
    except (Refused, OSError, ValueError) as error:
        print(f'[-] check-vm: {error}', file=sys.stderr)
        return 2, None, {'kind': 'input', 'stage': None, 'message': str(error), 'advice': None}


def check_command(args):
    if args.report is None:
        if args.owner is not None:
            print('[-] check-vm: --owner requires --report', file=sys.stderr)
            return 2
        code, report, _ = run_check_vm(args.vm, Path(args.components))
        if report is not None:
            print(json.dumps(report, indent=2, sort_keys=True))
        return code
    try:
        owner = parse_owner(args.owner)
        destination = open_destination(args.report, owner)
    except (Refused, OSError) as error:
        print(f'[-] check-vm: report {args.report}: {error}', file=sys.stderr)
        return 2
    try:
        code, report, error = run_check_vm(args.vm, Path(args.components))
        result = {'schema': RESULT_SCHEMA, 'exit_code': code, 'report': report, 'error': error,
                  'checked_as_uid': os.geteuid()}
        try:
            write_result(destination, owner, result)
        except OSError as failure:
            print(f'[-] check-vm: could not write the report {args.report}: {failure}', file=sys.stderr)
            return 2
    finally:
        os.close(destination[0])
    print(f'[*] check result (exit {code}) written to {args.report}'
          + (f' for uid {owner[0]}' if owner else ''), file=sys.stderr)
    return code


def main(argv):
    parser = argparse.ArgumentParser(prog='cfw_env_update.py', description=__doc__.split('\n\n', 1)[0])
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check-vm')
    check.add_argument('vm')
    check.add_argument('--components')
    check.add_argument('--report')
    check.add_argument('--owner')
    run = commands.add_parser('apply')
    run.add_argument('vm')
    run.add_argument('--device', required=True)
    run.add_argument('--mount', required=True)
    run.add_argument('--report', required=True)
    run.add_argument('--components')
    identity = commands.add_parser('identity')
    identity.add_argument('vm')
    identity.add_argument('--compare', required=True)
    args = parser.parse_args(argv)
    if getattr(args, 'components', None) is None and args.command != 'identity':
        args.components = os.environ.get('VPHONE_GUEST_COMPONENTS') or str(default_components())
    if args.command == 'check-vm':
        return check_command(args)
    try:
        if args.command == 'apply':
            return apply(args)
        return compare_identity(args.compare, Path(args.vm))
    except DiskAccess as error:
        print(f'[-] disk access failed at stage {error.stage}: {error}', file=sys.stderr)
        return 5
    except (Refused, OSError, ValueError) as error:
        print(f'[-] {args.command}: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

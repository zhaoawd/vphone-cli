"""Retire four approved old states, publish the approved amendment, then run EXP."""
import argparse
import copy
import datetime
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'research/evidence/t32-t33-retirement-20261025'
REVIEW = ROOT / 'research/evidence/t32-t33-storage-review-20261025'
WORK = ROOT / '.build/t32-t33-completion-20261023/exp-target-binding-acceptance-20261025'
OLD = 'b3b98f370e384a3659dea2428651cb033566e01a8641897651038a3701f8805b'
NEW = 'dd2799d50f0a3fbaa0edfe9af16e247f0c8b6cd8b9ea76e64ed99a8211b5a5bc'
NAMES = (
    '.build/t32-t33-completion-20261023/fresh-library/t32-t33-file-acceptance-20261023',
    '.build/t32r-20261023',
    '.build/t32-t33-completion-20261023/display-runtime/pre-runtime-backup',
    '.build/t32-t33-followup-20261023/pre-runtime-backup',
)
sys.path.insert(0, str(ROOT / 'research/upstream_integration_2026-10-15/tools'))
import execute_t33_target_binding_acceptance as acceptance


def sha(path):
    return acceptance.base.evidence.digest(Path(path))


def save(name, value):
    path = OUT / name
    data = json.dumps(value, ensure_ascii=False, indent=2).encode() + b'\n'
    with path.open('wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    path.chmod(0o644)


def metadata(path):
    info = path.lstat()
    result = {key: getattr(info, 'st_' + key) for key in
              ('dev', 'ino', 'mode', 'uid', 'gid', 'size', 'mtime_ns', 'ctime_ns', 'nlink', 'blocks')}
    result['flags'] = getattr(info, 'st_flags', 0)
    if stat.S_ISLNK(info.st_mode):
        result['link'] = os.readlink(path)
    return result


def inventory(path):
    result = {str(path.relative_to(ROOT)): metadata(path)}
    for directory, dirs, files in os.walk(path, followlinks=False,
                                         onerror=lambda error: (_ for _ in ()).throw(error)):
        if os.path.ismount(directory):
            raise ValueError('Mounted directory in retirement root: ' + directory)
        for name in dirs + files:
            item = Path(directory) / name
            observed = metadata(item)
            blocked = sum(getattr(stat, name, 0) for name in
                          ('UF_IMMUTABLE', 'UF_APPEND', 'SF_IMMUTABLE', 'SF_APPEND', 'SF_NOUNLINK'))
            if observed['flags'] & blocked:
                raise ValueError('File flags prevent approved removal: ' + str(item))
            if not (stat.S_ISDIR(observed['mode']) or stat.S_ISREG(observed['mode'])
                    or stat.S_ISLNK(observed['mode'])):
                raise ValueError('Special file in retirement root: ' + str(item))
            result[str(item.relative_to(ROOT))] = observed
    return result


def validate_roots(assessment, protected):
    rows = assessment['retirementTargets']
    if tuple(row['path'] for row in rows) != NAMES:
        raise ValueError('Retirement list differs from four approved roots')
    for row in rows:
        path = ROOT / row['path']
        if path.is_symlink() or path.resolve(strict=True) != path or not path.is_dir():
            raise ValueError('Linked or unexpected retirement root: ' + str(path))
        observed = metadata(path)
        if any(observed[key] != value for key, value in row['rootIdentity'].items()):
            raise ValueError('Retirement root identity changed: ' + str(path))
        if any(Path(name) == path or path in Path(name).parents for name in protected):
            raise ValueError('Protected input in retirement root: ' + str(path))
    return [ROOT / name for name in NAMES]


def unchanged_inputs(protected):
    for name, expected in protected.items():
        if sha(name) != expected:
            raise ValueError('Protected input changed: ' + name)


def unused(path):
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-F', 'pn', '+D', str(path)],
                            capture_output=True, text=True, timeout=60)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise ValueError('Open-handle inspection failed: ' + result.stderr)
    owner = None
    for line in result.stdout.splitlines():
        if line.startswith('p'):
            owner = int(line[1:])
        elif line.startswith('n') and owner != os.getpid():
            raise ValueError('Retirement root held by PID ' + str(owner) + ': ' + line[1:])


def attachments(targets):
    listing = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist'], timeout=30))
    for entry in listing.get('images', []):
        paths = [Path(entry['image-path'])] if entry.get('image-path') else []
        paths += [Path(entity['mount-point']) for entity in entry.get('system-entities', [])
                  if entity.get('mount-point')]
        if any(path == target or target in path.parents for target in targets for path in paths):
            raise ValueError('Retirement root has an attached image or mounted volume')


def acquire(path, handles, directory=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | (os.O_DIRECTORY if directory else 0))
    handles.append(fd)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return fd


def archive_small_records(inventories):
    output = OUT / 'retired-small-records.tar.gz'
    rows = []
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(fd)
    with tarfile.open(output, 'w:gz', dereference=False) as archive:
        for items in inventories.values():
            for name, expected in sorted(items.items()):
                path = ROOT / name
                if (not stat.S_ISREG(expected['mode']) or expected['size'] > 8 << 20
                        or path.suffix not in ('.json', '.jsonl', '.plist', '.log', '.txt', '.shsh')):
                    continue
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                try:
                    if metadata(path) != expected:
                        raise ValueError('Archive input changed: ' + name)
                    with os.fdopen(os.dup(fd), 'rb') as stream:
                        data = stream.read((8 << 20) + 1)
                    if len(data) != expected['size'] or metadata(path) != expected:
                        raise ValueError('Archive input changed during read: ' + name)
                    held = os.fstat(fd)
                    if (held.st_dev, held.st_ino, held.st_size, held.st_mtime_ns, held.st_ctime_ns) != tuple(
                            expected[key] for key in ('dev', 'ino', 'size', 'mtime_ns', 'ctime_ns')):
                        raise ValueError('Archive descriptor differs: ' + name)
                    member = tarfile.TarInfo(name)
                    member.size = len(data)
                    member.mode = stat.S_IMODE(expected['mode'])
                    member.uid = expected['uid']; member.gid = expected['gid']
                    member.mtime = expected['mtime_ns'] // 1_000_000_000
                    archive.addfile(member, io.BytesIO(data))
                    rows.append(dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
                finally:
                    os.close(fd)
    output.chmod(0o600)
    with tarfile.open(output) as archive:
        if archive.getnames() != [row['path'] for row in rows]:
            raise ValueError('Archived record member set differs')
        for row in rows:
            with archive.extractfile(row['path']) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != row['sha256']:
                    raise ValueError('Archived record content differs')
    save('retired-small-records-manifest.json', dict(files=rows, archiveSHA256=sha(output), fullDiskBackup=False))
    return len(rows)


def remove_verified(targets, inventories, removed):
    if not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError('Directory descriptor based rmtree is required')
    attachments(targets)
    # Recheck all four roots before the first deletion, then each root immediately before removal.
    for path in targets:
        unused(path)
        if inventory(path) != inventories[str(path.relative_to(ROOT))]:
            raise ValueError('Retirement inventory changed before removal')
    for path in targets:
        unused(path)
        if inventory(path) != inventories[str(path.relative_to(ROOT))]:
            raise ValueError('Retirement inventory changed during removal')
        shutil.rmtree(path)
        if os.path.lexists(path):
            raise ValueError('Retirement root remains')
        removed.append(str(path.relative_to(ROOT)))
        save('removal-progress.json', dict(removed=removed))
        print('Removed ' + removed[-1], flush=True)


def publish_amendment(raw, old_inputs):
    new_inputs = copy.deepcopy(old_inputs)
    new_inputs['planSHA256'] = NEW
    contents = {
        'offline-plan.json': raw,
        'executor-inputs.json': json.dumps(new_inputs, indent=2).encode() + b'\n',
        'approval.json': json.dumps(dict(approved=True, planSHA256=NEW), indent=2).encode() + b'\n',
    }
    for name, data in contents.items():
        path = WORK / name
        original = path.stat()
        preserved = WORK / (name + '.before-retirement-20261025')
        if preserved.exists():
            raise ValueError('Preserve prior amendment publication; no replay')
        os.rename(path, preserved)
        with path.open('xb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        path.chmod(stat.S_IMODE(original.st_mode))
        os.chown(path, original.st_uid, original.st_gid)
    fd = os.open(WORK, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    if sha(WORK / 'offline-plan.json') != NEW or sha(WORK / 'offline-plan.json.before-retirement-20261025') != OLD:
        raise ValueError('Plan publication readback differs')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply-approved', required=True)
    args = parser.parse_args()
    if args.apply_approved != NEW or os.geteuid() != 0:
        raise ValueError('Exact approved amendment and administrator authentication required')
    inputs = json.loads((OUT / 'cleanup-inputs.json').read_bytes())
    unchanged_inputs(inputs['files'])
    approval = json.loads((OUT / 'approval.json').read_bytes())
    if approval.get('approved') is not True or approval.get('amendedPlanSHA256') != NEW:
        raise ValueError('Explicit four-root approval missing')
    if (OUT / 'result.json').exists() or (WORK / 'execution').exists():
        raise ValueError('Prior cleanup or native execution exists; no replay')
    result = dict(state='checking', removed=[], VMStarts=0, CFWWrites=0, securityWindows=0)
    handles = []
    save('result.json', result)
    try:
        raw = (REVIEW / 'offline-plan-after-retirement.json').read_bytes()
        if hashlib.sha256(raw).hexdigest() != NEW or sha(WORK / 'offline-plan.json') != OLD:
            raise ValueError('Approved old/new plan bytes differ')
        old = json.loads((WORK / 'offline-plan.json').read_bytes())
        plan = acceptance.validate(json.loads(raw))
        if {key for key in old.keys() | plan.keys() if old.get(key) != plan.get(key)} != {
                'unrelatedDiskIdentities', 'preserve', 'retirementAmendment'}:
            raise ValueError('Amendment changes more than approved retirement scope')
        old_inputs = json.loads((WORK / 'executor-inputs.json').read_bytes())
        acceptance.configure(OLD)
        acceptance.base.approved(OLD); acceptance.base.verify_execution_inputs()
        protected = {**old['frozenInputs'], **old_inputs['files'], **inputs['files']}
        targets = validate_roots(json.loads((REVIEW / 'retirement-assessment.json').read_bytes()), protected)
        tracked = subprocess.check_output(['/usr/bin/git', '-c', 'safe.directory=' + str(ROOT),
            'ls-files', '-z', '--', *NAMES], cwd=ROOT)
        if tracked:
            raise ValueError('Tracked files in retirement roots')
        for path in targets:
            acquire(path, handles, directory=True)
        attachments(targets)
        acceptance.unrelated(old)
        inventories = {str(path.relative_to(ROOT)): inventory(path) for path in targets}
        for items in inventories.values():
            for name, observed in items.items():
                if stat.S_ISREG(observed['mode']) and Path(name).name in (
                        'Disk.img', 'guest-postimage.img', '.vphone-online-operation.lock', '.firmware-desired.lock'):
                    acquire(ROOT / name, handles)
        for path in targets:
            unused(path)
        unchanged_inputs(protected)
        result['sourceBaselineBefore'] = acceptance.base.baseline(plan)
        archive_count = archive_small_records(inventories)
        inventory_path = OUT / 'inventory.json.gz'
        inventory_path.write_bytes(gzip.compress(json.dumps(inventories).encode(), mtime=0))
        inventory_path.chmod(0o600)
        result.update(metadataFilesArchived=archive_count, inventoryEntries=sum(map(len, inventories.values())),
                      allocatedBytes=sum(row['blocks'] * 512 for rows in inventories.values() for row in rows.values()),
                      freeBytesBefore=shutil.disk_usage(ROOT).free, state='removing')
        save('result.json', result)
        remove_verified(targets, inventories, result['removed'])
        unchanged_inputs(protected)
        acceptance.unrelated(plan)
        result['sourceBaselineAfter'] = acceptance.base.baseline(plan)
        publish_amendment(raw, old_inputs)
        acceptance.configure(NEW)
        acceptance.base.approved(NEW); acceptance.base.verify_execution_inputs()
        result.update(state='completed', amendedPlanSHA256=NEW, protectedInputsVerified=len(protected),
                      preservedDiskIdentitiesVerified=len(plan['unrelatedDiskIdentities']),
                      freeBytesAfter=shutil.disk_usage(ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - result['freeBytesBefore']
        result['capacity75GiBPassed'] = result['freeBytesAfter'] >= plan['minimumInitialFreeBytes']
        save('result.json', result)
        print(json.dumps(result), flush=True)
    except Exception as error:
        result.update(state='failed', error=str(error))
        save('result.json', result)
        raise
    finally:
        for fd in reversed(handles):
            os.close(fd)
    if not result['capacity75GiBPassed']:
        save('pipeline-result.json', dict(state='awaiting-capacity', nativeStarted=False))
        return 0
    # The same administrator-authenticated parent starts the approved offline
    # runner once. A failure is final for this invocation; no retry or rollback.
    save('pipeline-result.json', dict(state='native-running', nativeStarted=True, planSHA256=NEW))
    with (WORK / 'root-execution.log').open('xb') as log:
        native = subprocess.run([sys.executable, str(Path(acceptance.__file__)),
            '--execute-approved-plan', NEW], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    save('pipeline-result.json', dict(state='native-finished', nativeStarted=True, exitCode=native.returncode,
                                     planSHA256=NEW))
    return native.returncode


if __name__ == '__main__':
    raise SystemExit(main())

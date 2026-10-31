#!/usr/bin/env python3
"""Explicit stopped-VM library maintenance; grants no firmware/Undo authority."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import sys
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))

import cfw_disk_txn as disk
import cfw_env_update as update

SCHEMA = 'vphone.t52-environment-maintenance.v1'
TARGET = ROOT / '.build/t51rt/lib/t52-v2'
TARGET_LIBRARIES = ['libcamfix.dylib', 'libvcamcaptured.dylib']
VERSION = '2.6.2-local.93805a71796d'
APPROVED = {'libcamfix.dylib': 'f387ff64ff4e8859f228fb42b0aa038cda0f16a040584048d55bbc2eff658a7d',
            'libvcamcaptured.dylib': 'eb2e366d0abd1184b1407e7e0c42799d4f7a95b10811239f756887d327904a3b'}
STORE = Path('/Library/Application Support/vphone-launchpad/Bundles')
METADATA = ('config.plist', 'launchpad.json', 'restore-info.json', '.firmware-desired-plan.json',
            '.firmware-component-receipts.json', 'udid-prediction.txt')


def strict(path, limit=8 << 20):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > limit:
            raise ValueError('Maintenance input must be a bounded single-link regular file')
        value = os.pread(fd, before.st_size, 0)
        after = os.fstat(fd)
        named = os.lstat(path)
        fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        if len(value) != before.st_size or any(getattr(before, k) != getattr(after, k) or
                                             getattr(before, k) != getattr(named, k) for k in fields):
            raise ValueError('Maintenance input changed during read')
        return value
    finally:
        os.close(fd)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def metadata(vm):
    return {name: sha(strict(vm / name)) for name in METADATA}


def image_identity(path):
    s = os.lstat(path)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
        raise ValueError('Maintenance disk must be a single-link regular file')
    return dict(dev=s.st_dev, ino=s.st_ino, size=s.st_size, mtime_ns=s.st_mtime_ns,
                uid=s.st_uid, gid=s.st_gid, mode=stat.S_IMODE(s.st_mode),
                birthtime=s.st_birthtime)


def qualified_bundle(vm, resources):
    version = json.loads(strict(vm / 'launchpad.json'))['bundle']
    if version != VERSION:
        raise ValueError('Core Bundle differs from the approved candidate')
    bundle = STORE / version / 'VPhone.bundle'
    if resources != bundle / 'Contents/Resources':
        raise ValueError('Maintenance must use the bound system Core Bundle')
    subprocess.run([str(bundle / 'Contents/MacOS/vphone-cli'), 'core-bundle', 'verify',
                    '--version', version], check=True, stdout=subprocess.DEVNULL)
    return version


def pending(vm):
    return any(p.name.startswith('.cfw_disk.') or p.name in
               ('.firmware-transaction', '.firmware-desired-pending.json') for p in vm.iterdir())


def prepare(vm, resources, precheck):
    if vm != TARGET:
        raise ValueError('This acceptance tool supports only the approved t52-v2 VM')
    if pending(vm):
        raise ValueError('Unfinished VM operation prevents maintenance preparation')
    version = qualified_bundle(vm, resources)
    info = json.loads(strict(vm / 'restore-info.json'))
    if info.get('variant') != 'regular' or info.get('guest_environment') != 'v2':
        raise ValueError('Maintenance supports recorded regular/v2 only')
    stage = resources / '.build/guest-components-v2/stage'
    candidates = update.candidates(stage, update.load_manifest())
    if {k: candidates[k]['sha256'] for k in TARGET_LIBRARIES} != APPROVED:
        raise ValueError('Camera library candidates differ from the approved bytes')
    rows = {r['name']: r['actual_sha256'] for r in precheck['libraries'] if r.get('scope') == 'local'}
    replace = precheck.get('replace', [])
    if precheck.get('classification') != 'offline_update' or set(rows) != set(candidates) or \
            sorted(replace) != TARGET_LIBRARIES or not set(replace) <= set(candidates) or len(replace) != len(set(replace)):
        raise ValueError('Maintenance requires a complete offline_update precheck')
    before = image_identity(vm / 'Disk.img')
    digest = disk.digest_path(vm / 'Disk.img')
    if image_identity(vm / 'Disk.img') != before:
        raise ValueError('Disk changed during maintenance preparation')
    return dict(schema=SCHEMA, id=str(uuid.uuid4()), vm=str(vm), resources=str(resources),
                bundleVersion=version, disk=before, diskSHA256=digest, metadata=metadata(vm),
                beforeLibraries=rows, candidates={k: v['sha256'] for k, v in candidates.items()},
                replace=sorted(replace), firmwareAuthority='unknown', undoAuthority='unknown')


def validate(plan, vm, resources, *, disk_required=True):
    if str(uuid.UUID(plan['id'])) != plan['id']:
        raise ValueError('Invalid maintenance plan identifier')
    if (vm != TARGET or plan.get('schema') != SCHEMA or plan.get('vm') != str(vm) or plan.get('resources') != str(resources)
            or plan.get('firmwareAuthority') != 'unknown' or plan.get('undoAuthority') != 'unknown'
            or plan.get('bundleVersion') != qualified_bundle(vm, resources)
            or plan.get('metadata') != metadata(vm)):
        raise ValueError('Maintenance VM, binding, metadata or scope changed')
    candidates = update.candidates(resources / '.build/guest-components-v2/stage', update.load_manifest())
    if {k: candidates[k]['sha256'] for k in TARGET_LIBRARIES} != APPROVED:
        raise ValueError('Camera library candidates differ from the approved bytes')
    if plan.get('candidates') != {k: v['sha256'] for k, v in candidates.items()} or \
            set(plan.get('beforeLibraries', {})) != set(candidates) or plan.get('replace') != TARGET_LIBRARIES or \
            not set(plan['replace']) <= set(candidates) or len(plan['replace']) != len(set(plan['replace'])):
        raise ValueError('Maintenance candidates or target list changed')
    if disk_required and (image_identity(vm / 'Disk.img') != plan['disk'] or
                          disk.digest_path(vm / 'Disk.img') != plan['diskSHA256']):
        raise ValueError('Maintenance disk identity or full SHA-256 changed')


def save(path, value):
    temporary = path.with_suffix('.new')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, path)
    sync_directory(path.parent)


def sync_directory(path):
    directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def mounted(image, root, readonly, action):
    flags = ['-readonly'] if readonly else []
    raw = update.run_tool([update.HDIUTIL, 'attach', *flags, '-nomount', '-plist',
                           '-imagekey', 'diskimage-class=CRawDiskImage', str(image)], 'attach')
    entities = plistlib.loads(raw).get('system-entities', [])
    bases = [r['dev-entry'] for r in entities if r.get('content-hint') == 'GUID_partition_scheme']
    if len(bases) != 1:
        raise ValueError('Maintenance attachment has no unique physical disk')
    base = bases[0]
    did_mount = False
    try:
        volume = update.system_volume(base)
        update.mount_volume(volume, root, readonly=readonly)
        did_mount = True
        return action(root)
    finally:
        # A failed unmount/detach leaves the pending directory and forbids swap.
        if did_mount:
            update.unmount(root)
        update.detach(base)


def same_original(plan, vm):
    if image_identity(vm / 'Disk.img') != plan['disk'] or metadata(vm) != plan['metadata']:
        raise ValueError('Source disk or VM metadata changed during maintenance')


def apply_plan(plan, vm, resources, mount_parent, *, fault=lambda stage: None):
    validate(plan, vm, resources)
    if pending(vm):
        raise ValueError('Unfinished VM operation prevents maintenance')
    disk.require_unheld(vm / 'Disk.img', os.getpid(), 'maintenance disk')
    disk.require_free_space([vm, mount_parent], minimum=2 << 30)
    work = Path(tempfile.mkdtemp(prefix='.cfw_disk.', dir=vm))
    journal = dict(version=5, operation=SCHEMA, id='environment-' + plan['id'], vm=str(vm),
                   status='preparing', plan=plan, firmwareAuthority='unknown', undoAuthority='unknown')
    save(work / 'transaction.json', journal)
    source_fd = os.open(vm / 'Disk.img', os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    stage = work / 'Disk.img'
    try:
        disk.clone_file(source_fd, stage)
        disk.set_owner_and_mode(stage, plan['disk'])
        if disk.digest_path(stage) != plan['diskSHA256']:
            raise ValueError('Maintenance clone differs from the full source digest')
        journal['status'] = 'staged'; save(work / 'transaction.json', journal)
        mount = disk.make_mount_directory(mount_parent)
        journal['mountRoot'] = disk.mount_identity(mount)
        save(work / 'transaction.json', journal)
        stage_components = resources / '.build/guest-components-v2/stage'

        def install(root):
            before = update.assess(root, vm, stage_components)
            observed = {r['name']: r['actual_sha256'] for r in before['libraries'] if r.get('scope') == 'local'}
            if before['classification'] != 'offline_update' or observed != plan['beforeLibraries'] or \
                    sorted(before['replace']) != plan['replace']:
                raise ValueError('Mounted library inputs differ from maintenance scope')
            fault('before-write')
            if update.apply_mounted(root, vm, stage_components, work / 'environment-update.json') != 0:
                raise ValueError('Maintenance replacement failed')

        mounted(stage, mount, False, install)
        fault('after-write')
        final = mounted(stage, mount, True, lambda root: update.assess(root, vm, stage_components))
        if final['classification'] != 'already_current':
            raise ValueError('Final read-only library verification failed')
        mount.rmdir()
        sync_image = os.open(stage, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fsync(sync_image)
        finally:
            os.close(sync_image)
        journal.update(status='verified', staged=image_identity(stage), stagedSHA256=disk.digest_path(stage),
                       reportSHA256=sha(strict(work / 'environment-update.json')))
        save(work / 'transaction.json', journal)
        same_original(plan, vm)
        fault('before-swap')
        disk.require_unheld(vm / 'Disk.img', os.getpid(), 'maintenance disk')
        disk.require_unheld(stage, os.getpid(), 'maintenance staged disk')
        journal['status'] = 'swapping'; save(work / 'transaction.json', journal)
        disk.swap_files(vm / 'Disk.img', stage)
        sync_directory(vm)
        sync_directory(work)
        fault('after-swap')
        journal['status'] = 'published'; save(work / 'transaction.json', journal)
        return finalize(work, journal)
    except BaseException:
        # Every failure keeps all disk/evidence files. Pending work prevents boot.
        raise
    finally:
        os.close(source_fd)


def finalize(work, journal):
    vm = Path(journal['vm'])
    if image_identity(vm / 'Disk.img') != journal['staged'] or \
            disk.digest_path(vm / 'Disk.img') != journal['stagedSHA256'] or \
            metadata(vm) != journal['plan']['metadata'] or \
            sha(strict(work / 'environment-update.json')) != journal['reportSHA256'] or \
            image_identity(work / 'Disk.img') != journal['plan']['disk'] or \
            disk.digest_path(work / 'Disk.img') != journal['plan']['diskSHA256']:
        raise ValueError('Published maintenance files or retained original differ')
    journal['status'] = 'published'
    save(work / 'transaction.json', journal)
    archive = archive_work(work, journal)
    return dict(state='published', archive=str(archive), plan=journal['plan'],
                currentSHA256=journal['stagedSHA256'], firmwareAuthority='unknown', undoAuthority='unknown')


def archive_work(work, journal):
    vm = Path(journal['vm'])
    archive = vm / '.environment-history' / journal['id']
    archive.parent.mkdir(exist_ok=True)
    if archive.parent.is_symlink() or not archive.parent.is_dir():
        raise ValueError('Maintenance archive parent must be a real directory')
    # Only this transaction's known files are handed back to the VM owner.
    owner = journal['plan']['disk']
    for name in ('Disk.img', 'transaction.json', 'environment-update.json'):
        path = work / name
        if path.exists():
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                s = os.fstat(fd)
                if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
                    raise ValueError('Maintenance archive contains an unsafe file')
                if (s.st_uid, s.st_gid) != (owner['uid'], owner['gid']):
                    os.fchown(fd, owner['uid'], owner['gid'])
            finally:
                os.close(fd)
    for path in (work, archive.parent):
        s = os.lstat(path)
        if (s.st_uid, s.st_gid) != (owner['uid'], owner['gid']):
            os.chown(path, owner['uid'], owner['gid'], follow_symlinks=False)
    disk.move_exclusive(work, archive)
    sync_directory(vm)
    sync_directory(archive.parent)
    return archive


def recover(work, journal, vm, resources):
    if (work.parent != vm or work.is_symlink() or not work.name.startswith('.cfw_disk.') or
            journal.get('version') != 5 or journal.get('operation') != SCHEMA or
            journal.get('vm') != str(vm) or journal.get('id') != 'environment-' + journal['plan']['id']):
        raise ValueError('Not the named environment maintenance transaction')
    validate(journal['plan'], vm, resources, disk_required=False)
    disk.require_unheld(vm / 'Disk.img', os.getpid(), 'recovery disk')
    if (work / 'Disk.img').exists():
        disk.require_unheld(work / 'Disk.img', os.getpid(), 'recovery staged disk')
    if image_identity(vm / 'Disk.img') == journal['plan']['disk']:
        # A failed pre-publication transaction can be archived only after the
        # complete original digest and all metadata are independently rechecked.
        validate(journal['plan'], vm, resources)
        mount_record = journal.get('mountRoot')
        if mount_record:
            root = Path(mount_record['path'])
            if root.exists():
                if disk.mount_identity(root) != mount_record:
                    raise ValueError('Recovery mount root was replaced or remains mounted')
                root.rmdir()  # Empty scratch created by this transaction only.
        journal['status'] = 'aborted-original-preserved'
        save(work / 'transaction.json', journal)
        return dict(state=journal['status'], archive=str(archive_work(work, journal)),
                    firmwareAuthority='unknown', undoAuthority='unknown')
    if journal.get('status') not in ('swapping', 'published'):
        raise ValueError('Unexpected disk identity; manual review required')
    return finalize(work, journal)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'apply', 'recover'])
    parser.add_argument('vm', type=Path)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--precheck', type=Path)
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--plan-sha256')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--work-parent', type=Path, default=Path('/private/tmp'))
    args = parser.parse_args()
    vm, resources = args.vm.resolve(strict=True), args.resources.resolve(strict=True)
    lock = os.open(vm, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.command == 'prepare':
            plan = prepare(vm, resources, json.loads(strict(args.precheck)))
            path = vm / ('.environment-maintenance-' + plan['id'] + '.json')
            save(path, plan)
            print(json.dumps(dict(path=str(path), sha256=sha(strict(path)))))
            return
        if os.geteuid() != 0:
            raise ValueError('Administrator authentication required')
        if args.command == 'recover':
            if args.work.parent.resolve() != vm or not args.work.name.startswith('.cfw_disk.'):
                raise ValueError('Recovery work differs from the named VM')
            journal = json.loads(strict(args.work / 'transaction.json'))
            result = recover(args.work, journal, vm, resources)
        else:
            raw = strict(args.plan)
            if sha(raw) != args.plan_sha256:
                raise ValueError('Maintenance plan digest changed')
            result = apply_plan(json.loads(raw), vm, resources, args.work_parent)
        print(json.dumps(result))
    finally:
        os.close(lock)


if __name__ == '__main__':
    main()

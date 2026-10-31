#!/usr/bin/env python3
"""Stopped-VM T52 System-only candidate transaction; preserves encrypted Data and old disk."""
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

SCHEMA = 'vphone.t52-system-consumer-maintenance.v1'
TARGET = ROOT / '.build/t51rt/lib/t52-v2'
TARGET_LIBRARIES = sorted(['libcamfix.dylib', 'libvlocation.dylib', 'libvcamcaptured.dylib', 'launchdhook-vphone.dylib', 'SystemHook-vphone.dylib'])
VERSION = '2.6.2-local.cc05d88f441f'
APPROVED = {'libcamfix.dylib': 'af3865decfe65e3ff01dc6865e6b579a0e401b322bf4a5afdeeeb0a49e86e428', 'libvlocation.dylib': 'cd9a7698d31b00b1b4dc6300768837886a620e17918592d3bf4183f4dd3cc743', 'launchdhook-vphone.dylib': 'c3814103036bf8c8f2f3f44677efec258190637de54db2d88cc6f63f3034a30f', 'SystemHook-vphone.dylib': 'b24ae1e9b9a61c00f50ea230da28e8f0f7a69669e9985ba631a082fcbf7c2bcc', 'libvcamcaptured.dylib': '1bb6602a22a4da2ffa2ddd30dafcdc34f99362df42e0aa7f1d0ed6bea7bcef45'}
API_SHA256 = 'f5ce73f00f5694b1639d735af8106436aaf2cfd1bd3dc7211aef6041149cd2a8'
BEFORE_API_SHA256 = '9b60814f8ded00608571fdcbfd53475ed2d6280955046a79fe45dc604efff101'
STORE = Path('/Library/Application Support/vphone-launchpad/Bundles')
METADATA = ('config.plist', 'launchpad.json', 'restore-info.json', '.firmware-desired-plan.json',
            '.firmware-component-receipts.json', 'udid-prediction.txt')
GUEST_OWNER = 0


def extra_candidates(resources):
    api = resources / '.build/daemon-api-v2/candidate-v2/vphoned'
    if sha(strict(api, 64 << 20)) != API_SHA256:
        raise ValueError('API candidate differs from fixed bytes')
    return {'api': {'source': str(api), 'sha256': API_SHA256}}


def checked_executable(path, expected):
    info = os.lstat(path)
    if info.st_uid != GUEST_OWNER or stat.S_IMODE(info.st_mode) != 0o755 or \
            sha(strict(path, 64 << 20)) != expected:
        raise ValueError('Extra executable ownership, mode or SHA-256 differs')


def real_directories(root, relative):
    current = root
    for part in Path(relative).parts:
        current = current / part
        if not stat.S_ISDIR(os.lstat(current).st_mode):
            raise ValueError('Mounted executable parent must be a real directory')


def check_extra_inputs(root, plan, *, after=False):
    # Data is encrypted/locked on the host. No Data volume is mounted here.
    # The API and publisher caches are checked through the guest after boot.
    for relative in ('usr/bin', 'usr/lib'):
        real_directories(root, relative)
    checked_executable(root / 'usr/bin/vphoned-api', API_SHA256 if after else BEFORE_API_SHA256)
    if plan['extraCandidates'] != extra_candidates(Path(plan['resources'])):
        raise ValueError('Extra candidate scope changed')


def replace_extras(root, plan):
    check_extra_inputs(root, plan)
    update.replace_file(Path(plan['extraCandidates']['api']['source']), root / 'usr/bin/vphoned-api')
    check_extra_inputs(root, plan, after=True)


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
    extras = extra_candidates(resources)
    if precheck.get('daemon', {}).get('sha256') != BEFORE_API_SHA256 or \
            precheck.get('daemon', {}).get('launchd_key_present') is not True:
        raise ValueError('API daemon precheck differs from fixed input')
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
                replace=sorted(replace), extraCandidates=extras,
                firmwareAuthority='unknown', undoAuthority='unknown')


def validate(plan, vm, resources, *, disk_required=True):
    if str(uuid.UUID(plan['id'])) != plan['id']:
        raise ValueError('Invalid maintenance plan identifier')
    if (vm != TARGET or plan.get('schema') != SCHEMA or plan.get('vm') != str(vm) or plan.get('resources') != str(resources)
            or plan.get('firmwareAuthority') != 'unknown' or plan.get('undoAuthority') != 'unknown'
            or plan.get('bundleVersion') != qualified_bundle(vm, resources)
            or plan.get('metadata') != metadata(vm)):
        raise ValueError('Maintenance VM, binding, metadata or scope changed')
    candidates = update.candidates(resources / '.build/guest-components-v2/stage', update.load_manifest())
    if plan.get('extraCandidates') != extra_candidates(resources):
        raise ValueError('Extra executable scope changed')
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
            check_extra_inputs(root, plan)
            fault('before-write')
            if update.apply_mounted(root, vm, stage_components, work / 'environment-update.json') != 0:
                raise ValueError('Maintenance replacement failed')
            replace_extras(root, plan)
            report = json.loads(strict(work / 'environment-update.json'))
            report['extraReplacements'] = plan['extraCandidates']
            save(work / 'environment-update.json', report)

        mounted(stage, mount, False, install)
        fault('after-write')
        def readback(root):
            check_extra_inputs(root, plan, after=True)
            return update.assess(root, vm, stage_components)
        final = mounted(stage, mount, True, readback)
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
        for mount_record in [journal.get('mountRoot')]:
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


def check_current(vm, resources, mount_parent, *, after=False):
    if vm != TARGET or pending(vm):
        raise ValueError('Read-only check requires the named VM without pending work')
    qualified_bundle(vm, resources)
    disk.require_unheld(vm / 'Disk.img', os.getpid(), 'check disk')
    system = disk.make_mount_directory(mount_parent)
    plan = {'resources': str(resources), 'extraCandidates': extra_candidates(resources)}
    def inspect(root):
        check_extra_inputs(root, plan, after=after)
        report = update.assess(root, vm, resources / '.build/guest-components-v2/stage')
        report['extraExecutablesVerified'] = 'after' if after else 'before'
        return report
    # A mount failure preserves its directories for review.
    report = mounted(vm / 'Disk.img', system, True, inspect)
    system.rmdir()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'prepare', 'apply', 'recover'])
    parser.add_argument('vm', type=Path)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--precheck', type=Path)
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--plan-sha256')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--work-parent', type=Path, default=Path('/private/tmp'))
    parser.add_argument('--after', action='store_true')
    parser.add_argument('--report', type=Path)
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
        if args.command == 'check':
            report = check_current(vm, resources, args.work_parent, after=args.after)
            save(args.report, report)
            print(json.dumps(dict(classification=report['classification'], replace=report['replace'],
                                  extraExecutablesVerified=report['extraExecutablesVerified'])))
            return
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

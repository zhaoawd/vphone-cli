#!/usr/bin/env python3
"""Independently inspect installed CFW targets on a stopped, readonly image.

No installer, snapshot rename, source publication or Undo writer is invoked.
The existing historical Receipt remains distinct from this observation.
"""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cfw_disk_txn as transaction
import cfw_guest_evidence as evidence
import vm_lock
from patchers import final_guest, guest_undo, installed_effects


@contextlib.contextmanager
def locked_vm(vm):
    if vm.is_symlink() or vm.resolve(strict=True) != vm:
        raise ValueError('audit VM must be an exact directory path')
    fd = os.open(vm, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    previous = os.environ.get(vm_lock.FD_ENV)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ[vm_lock.FD_ENV] = str(fd)
        vm_lock.check_inherited(vm)
        if any(vm.glob('.cfw_disk.*')) or (vm/'.firmware-desired-pending.json').exists():
            raise ValueError('unfinished VM publication prevents installed-effect audit')
        yield
    finally:
        if previous is None: os.environ.pop(vm_lock.FD_ENV, None)
        else: os.environ[vm_lock.FD_ENV] = previous
        os.close(fd)


def run_tool(argv):
    return subprocess.run(argv, check=True, capture_output=True, timeout=30).stdout


@contextlib.contextmanager
def readonly_roots(image, wanted, parent):
    if parent.is_symlink(): raise ValueError('audit workspace parent must not be linked')
    parent = parent.resolve(strict=True)
    if not parent.is_dir(): raise ValueError('audit workspace parent must be a directory')
    attached = plistlib.loads(run_tool(['/usr/bin/hdiutil', 'info', '-plist']))
    if any(Path(row.get('image-path', '')).absolute() == image for row in attached.get('images', [])):
        raise ValueError('audit image is already attached; preserve existing attachment')
    workspace = Path(tempfile.mkdtemp(prefix='cfw-readonly-', dir=parent))
    base = None; mounted = []; roots = {}; identities = {}
    try:
        info = plistlib.loads(run_tool(['/usr/bin/hdiutil', 'attach', '-readonly', '-nomount', '-plist',
                                       '-imagekey', 'diskimage-class=CRawDiskImage', str(image)]))
        bases = [row['dev-entry'] for row in info.get('system-entities', [])
                 if row.get('content-hint') == 'GUID_partition_scheme']
        if len(bases) != 1: raise ValueError('audit attachment has no unique physical disk')
        base = bases[0]
        initial = final_guest.attachments(image)
        reference = initial['ContainerReference']
        for volume in sorted(wanted):
            device = reference + final_guest.VOLUMES[volume][1]
            if len([row for row in initial['Volumes'] if row.get('DeviceIdentifier') == device]) != 1:
                raise ValueError('audit volume is not unique on the attached image')
            if final_guest.mount_point(final_guest.volume_info(device), device) is not None:
                raise ValueError('audit volume was mounted by another operation')
            root = workspace / volume; root.mkdir(mode=0o700)
            run_tool(['/sbin/mount_apfs', '-o', 'rdonly,nobrowse', '/dev/'+device, str(root)])
            mounted.append(root)
            final_guest.require_mount(root, device, True)
            if not os.statvfs(root).f_flag & os.ST_RDONLY:
                raise ValueError('audit filesystem is not readonly')
            s = root.lstat(); identities[volume] = (s.st_dev, s.st_ino)
            roots[volume] = root
        if 'system' in roots: roots['dsc'] = roots['system'] / 'System/Cryptexes/OS/System/Library/Caches/com.apple.dyld'
        attachment = final_guest.attachments(image)
        if (attachment['ContainerReference'] != reference or attachment['PhysicalStores'] != initial['PhysicalStores']):
            raise ValueError('audit image physical binding changed while mounting')
        def recheck():
            if final_guest.attachments(image) != attachment:
                raise ValueError('audit image attachment changed')
            for volume in wanted:
                root = roots[volume]; s = root.lstat()
                if (s.st_dev, s.st_ino) != identities[volume] or not os.statvfs(root).f_flag & os.ST_RDONLY:
                    raise ValueError('audit mount changed')
                final_guest.require_mount(root, reference+final_guest.VOLUMES[volume][1], True)
        recheck()
        yield roots, recheck
        recheck()
    finally:
        # Only normally unmount mounts created by this invocation. Failure
        # preserves the attachment and workspace; no force or broad cleanup.
        for root in reversed(mounted): run_tool(['/sbin/umount', str(root)])
        if base is not None: run_tool(['/usr/bin/hdiutil', 'detach', base])
        for root in workspace.iterdir(): root.rmdir()
        workspace.rmdir()


def audit_locked(vm, parent):
    transaction.require_lock(vm)
    image = vm / transaction.DISK
    transaction.require_unheld(image, os.getpid(), 'installed-effect audit disk')
    fd = os.open(image, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        committed = transaction.committed_guest_evidence(vm)
        if committed is None: raise ValueError('no committed guest publication; installed effects cannot be qualified')
        archive, record, checkpoint, final = committed
        rows = [json.loads(line) for line in evidence.read(archive/evidence.OPERATIONS).splitlines()]
        index = json.loads(evidence.read(archive/evidence.UNDO))
        plan = guest_undo.saved_plan(archive, checkpoint['generationID'])
        wanted = {row['target'].split(':', 1)[0] for row in final['outputs']}
        wanted.discard('dsc'); wanted.add('system')
        if not wanted.issubset(final_guest.VOLUMES): raise ValueError('unknown installed volume')
        with readonly_roots(image, wanted, parent) as (roots, recheck):
            compared = installed_effects.verify_targets(final['outputs'], roots)
            pages = []
            for entry in index['entries']:
                target = installed_effects.target_path(entry['target'], roots)
                try:
                    count = guest_undo.verify_code_pages(target)
                    pages.append(dict(target=entry['target'], passed=True, verifiedCodePages=count))
                except (ValueError, OSError) as error:
                    pages.append(dict(target=entry['target'], passed=False, error=str(error)))
            from patchers import undo_provenance
            undo_provenance.recheck_sources(plan, rows, archive/evidence.STORE)
            recheck()
        # Reauthenticate the entire publication and source association after
        # the independent target read, rather than trusting cached receipts.
        if transaction.committed_guest_evidence(vm) != committed:
            raise ValueError('publication changed during installed-effect audit')
        evidence.unchanged(image, fd, before)
        passed = compared['passed'] and all(row['passed'] for row in pages)
        return dict(schemaVersion=1, state='verified-installed-effects' if passed else 'installed-effect-mismatch',
                    passed=passed, scope=compared['scope'], vm=str(vm), transactionID=record['id'],
                    generationID=checkpoint['generationID'], imageIdentity=evidence.image_identity(before),
                    publicationImageSHA256=checkpoint['imageSHA256'],
                    currentImageSHA256=checkpoint.get('currentImageSHA256', checkpoint['imageSHA256']),
                    publicationCheckpointSHA256=record['guestEvidenceSHA256'],
                    authenticatedDSCSourceAssociation=bool(index['entries']),
                    authenticatedDSCEntries=len(index['entries']),
                    sourceScope='generation-originals-and-publication-chain' if index['entries'] else 'publication-chain-only',
                    targets=compared['targets'], codePages=pages,
                    undoEligibility=installed_effects.undo_eligibility(rows, index),
                    runtimeValidated=False, originQualified=False, writeAuthorized=False,
                    cleanup=dict(mountsReleased=True, imageDetached=True))
    finally: os.close(fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('vm', type=Path)
    parser.add_argument('--work-parent', type=Path, required=True)
    parser.add_argument('--report', type=Path, help='Exclusive new JSON report, including mismatches and refusals')
    parser.add_argument('--owner', help='Report owner UID[:GID]; requires --report')
    args = parser.parse_args(argv)
    if args.owner and not args.report: parser.error('--owner requires --report')
    vm = args.vm.absolute()
    destination = None
    from cfw_env_update import Refused as ReportRefused, open_destination, parse_owner, write_result
    try:
        owner = parse_owner(args.owner)
        if args.report: destination = open_destination(args.report, owner)
        try:
            with locked_vm(vm): report = audit_locked(vm, args.work_parent)
            code = 0 if report['passed'] else 1
        except (OSError, ValueError, transaction.Refused, subprocess.SubprocessError) as error:
            report = dict(schemaVersion=1, state='audit-refused', passed=False, vm=str(vm),
                          error=str(error), writeAuthorized=False, runtimeValidated=False, originQualified=False)
            code = 2
        if destination:
            write_result(destination, owner, report)
            print(json.dumps(dict(state=report['state'], passed=report['passed'], report=str(args.report), exitCode=code)))
        else: print(json.dumps(report, sort_keys=True))
        return code
    except (OSError, ReportRefused) as error:
        print('Cannot create audit report: ' + str(error), file=sys.stderr)
        return 2
    finally:
        if destination: os.close(destination[0])


if __name__ == '__main__': raise SystemExit(main())

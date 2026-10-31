"""Replace the one dev payload without a host metadata extraction round trip."""
import copy
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import tarfile
import tempfile

if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from patchers import component_effects as effects
from patchers import guest_write, plan_gate as gate

MEMBER = 'iosbinpack64/usr/local/bin/rpcserver_ios'


def replace_payload(archive, payload):
    archive, payload = Path(archive), Path(payload)
    if archive.resolve() == payload.resolve():
        raise ValueError('Overlay payload must differ from archive')
    guest_write.archive_targets(archive, archive.parent / '.overlay-validation')
    original = archive.lstat()
    keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_uid', 'st_gid', 'st_nlink')
    with tempfile.TemporaryDirectory(prefix='.dev-overlay-', dir=archive.parent) as temporary:
        output = Path(temporary) / archive.name
        replaced = 0
        with effects.regular(archive) as source, effects.regular(payload) as replacement:
            with tarfile.open(fileobj=source, mode='r:') as old:
                members = old.getmembers()
                targets = [member for member in members if str(PurePosixPath(member.name)) == MEMBER]
                if len(targets) != 1:
                    raise ValueError('Exactly one dev overlay member is required')
                target = targets[0]
                if not target.isfile():
                    raise ValueError('Overlay target must be a regular archive member')
                if target.size == os.fstat(replacement.fileno()).st_size:
                    with old.extractfile(target) as existing:
                        if hashlib.file_digest(existing, 'sha256').digest() == hashlib.file_digest(replacement, 'sha256').digest():
                            return False
                    replacement.seek(0)
                with tarfile.open(output, mode='w:') as new:
                    for member in members:
                        if member is target:
                            updated = copy.copy(member)
                            updated.pax_headers = dict(member.pax_headers)
                            updated.size = os.fstat(replacement.fileno()).st_size
                            # A PAX size field must agree with the new payload.
                            if 'size' in updated.pax_headers:
                                updated.pax_headers['size'] = str(updated.size)
                            new.addfile(updated, replacement)
                            replaced += 1
                        else:
                            new.addfile(member, old.extractfile(member) if member.isfile() else None)
        if replaced != 1:
            raise ValueError('Exactly one dev overlay member is required')
        guest_write.archive_targets(output, archive.parent / '.overlay-validation')
        os.chmod(output, stat.S_IMODE(original.st_mode))
        if os.geteuid() == 0:
            os.chown(output, original.st_uid, original.st_gid)
        with output.open('rb') as stream:
            os.fsync(stream.fileno())
        current = archive.lstat()
        if any(getattr(current, key) != getattr(original, key) for key in keys):
            raise ValueError('Overlay archive changed before publication')
        os.replace(output, archive)
        fd = os.open(archive.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    return True


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2:
        raise ValueError('Archive and exact dev payload required')
    plan = gate.from_environment()
    gate.require_write_context(plan)
    if plan.context['variant'] != 'exp':
        raise ValueError('This overlay entrypoint requires EXP')
    archive = gate.private_path(plan, Path(args[0]))
    if archive != Path(plan.context['vmDirectory']) / 'cfw_input/jb/iosbinpack64.tar':
        raise ValueError('Overlay archive differs from the fixed CFW input')
    scripts = Path(__file__).resolve().parents[1]
    payload = Path(args[1])
    if payload not in (scripts / 'resources/cfw_dev/rpcserver_ios', scripts / 'cfw_dev/rpcserver_ios'):
        raise ValueError('Overlay payload differs from the packaged dev resource')
    gate.authorize(plan, 'system-iosbinpack-boot-install', 'system:/iosbinpack64')
    gate.recheck(plan)
    replace_payload(archive, payload)
    gate.recheck(plan)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print('[-] frozen plan: ' + str(error), file=sys.stderr)
        raise SystemExit(1)

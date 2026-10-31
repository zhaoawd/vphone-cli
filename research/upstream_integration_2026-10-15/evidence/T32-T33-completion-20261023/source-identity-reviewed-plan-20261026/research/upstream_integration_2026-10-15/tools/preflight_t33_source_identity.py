"""Read the actual complete Undo preview and preserved source with packaged code.

Only the source-registration reader is replaced with a fully verified in-memory
binding. Historical qualifiers, source bytes and the production comparison code
remain unchanged. This creates no operational registration or transaction.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / '.build/t32-t33-completion-20261023'
VM = ROOT / '.build/t33t-20261025'
OUT = BASE / 'source-identity-packaged-preflight-20261026'
SCRIPTS = BASE / 'exp-source-identity-package-20261026/VPhone.bundle/Contents/Resources/scripts'
sys.path.insert(0, str(SCRIPTS))
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence
import cfw_reboot_identity as disk_identity
import cfw_source_identity as source_identity
import vm_lock
from patchers import file_originals, guest_recovery, guest_undo, undo_provenance as undo


def snapshot(path):
    info = path.lstat()
    with path.open('rb') as stream: digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if source_identity.metadata(path.lstat()) != source_identity.metadata(info):
        raise ValueError('Readonly preparation input changed')
    return dict(sha256=digest, bytes=info.st_size, dev=info.st_dev, ino=info.st_ino,
        mtime_ns=info.st_mtime_ns, mode=info.st_mode & 0o7777, uid=info.st_uid, gid=info.st_gid)


def main():
    if os.geteuid() != 0: raise ValueError('Private source preflight requires readonly administrator authentication')
    OUT.mkdir()
    if (VM / source_identity.REGISTRATION).exists(): raise ValueError('This probe cannot replace an operational source registration')
    fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    previous = os.environ.get(vm_lock.FD_ENV)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); os.environ[vm_lock.FD_ENV] = str(fd); vm_lock.check_inherited(VM)
        empty = VM / '.cfw_disk.reboot20261026'
        if list(VM.glob('.cfw_disk.*')) != [empty] or list(empty.iterdir()):
            raise ValueError('Only the retained empty failed work directory is expected')
        empty_before = source_identity.metadata(empty.lstat())
        txn.require_unheld(VM / 'Disk.img', os.getpid(), 'complete readonly Undo/source preflight')
        volume = disk_identity._volume_uuid(VM)
        original_disk_registration = evidence.digest(VM / disk_identity.REGISTRATION)
        binding = disk_identity.load_registered(VM, 'e45c2fedee57f70b05bf7e4fe8fc6946b21b0aded7dadf4f66760f0304274308', volume)
        if binding is None or original_disk_registration != 'b15ab16b9ca6a440d704ae32aa58f5edc0602a034f451577b848ce00c1354ad3':
            raise ValueError('Existing approved four-image registration differs')
        binding.verify_files(volume)
        parent = txn.committed_guest_evidence(VM)
        if parent is None or parent[1]['id'] != '20261025T132920Z-adMN63qO':
            raise ValueError('Current first-on publication did not qualify')
        plan = guest_undo.saved_plan(parent[0], parent[2]['generationID'])
        catalog = json.loads(evidence.read(parent[0] / file_originals.FILENAME))
        members = []
        for source in catalog['sources']:
            path = Path(source['source'])
            members.append(dict(path=str(path.relative_to(VM)), recordedQualification=source['generationSource'],
                currentQualification=undo.qualify_source(plan, path), currentMetadata=source_identity.metadata(path.lstat())))
        explicit = source_identity.SourceBinding(VM, plan.context['generationID'], volume, members)
        explicit.verify_files(plan, volume)
        protected = {str(path): evidence.digest(path) for path in (
            Path(__file__), SCRIPTS / 'cfw_source_identity.py', SCRIPTS / 'patchers/undo_provenance.py',
            SCRIPTS / 'patchers/file_originals.py', parent[0] / 'transaction.json', parent[0] / evidence.CHECKPOINT,
            VM / 'launchpad.json', VM / disk_identity.REGISTRATION)}
        declarations = ['system-systemversion-cfw-build_version']
        try: guest_undo.preview(VM, plan.context['generationID'], declarations, _committed=parent)
        except ValueError as error:
            if str(error) != 'Undo source no longer matches original observation': raise
        else: raise ValueError('Unregistered source unexpectedly gained authority')
        source = VM / '.cfw-recovery-sources/20261025T144138Z-W7aZSh3x'
        expected = dict(recordSHA256='9f98451c4be8c4d4d71c8677d36759bac78ad4d1e27467f5de915024b6296c27',
            imageSHA256='bdebbae8f46128d2ac9bb57c4fb3a61c6aba8ab120d8607f56f81b60e2a792ef')
        with patch.object(source_identity, 'binding_for', return_value=explicit):
            preview = guest_undo.preview(VM, plan.context['generationID'], declarations, _committed=parent)
            record, request, files = guest_recovery.verify_source(VM, source, expected, preview, parent)
            file_originals.load(plan, source / evidence.STORE)
        if len(preview['entries']) != 2 or {row['kind'] for row in preview['entries']} != {'data'}:
            raise ValueError('Complete SystemVersion declaration selection differs')
        old_plan = json.loads(evidence.read(BASE / 'exp-reboot-recovery-acceptance-20261026/offline-plan.json'))
        boot = {name: snapshot(VM / name) for name in old_plan['targets'][0]['currentBootFiles']}
        host = {name: snapshot(VM / name) for name in ('launchpad.json', '.vphone-runtime.json', '.ssh_forward', disk_identity.REGISTRATION)}
        for name, digest in protected.items():
            if evidence.digest(Path(name)) != digest: raise ValueError('Protected candidate or historical source changed')
        if list(empty.iterdir()) or source_identity.metadata(empty.lstat()) != empty_before:
            raise ValueError('Retained empty failed work changed during readonly preflight')
        result = dict(passed=True, completeFourImageReadbacksPassed=True, completeParentPublicationPassed=True,
            productionCompleteUndoPreviewPassed=True, rebuiltIndexByteIdentical=True,
            preservedUndoSourceVerified=True, preservedSourceFiles=files, preservedRecordSHA256=expected['recordSHA256'],
            sourceMembers=members, currentBootFiles=boot, currentHostFiles=host, volumeUUID=volume,
            emptyFailedWork=dict(path=str(empty), metadata=empty_before, entries=[]),
            candidateModulesSHA256={str(p.relative_to(SCRIPTS)): evidence.digest(p) for p in SCRIPTS.rglob('*.py')},
            preview=preview, sourceRegistrationInstalled=False, transactionWrites=0, VMStarts=0, accepted=False,
            limitation='production comparison and actual complete preview/source read under a verified in-memory source binding; no operational source authority installed')
        (OUT / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k not in ('currentBootFiles', 'currentHostFiles', 'candidateModulesSHA256', 'preview', 'sourceMembers', 'preservedSourceFiles')}), flush=True)
    finally:
        if previous is None: os.environ.pop(vm_lock.FD_ENV, None)
        else: os.environ[vm_lock.FD_ENV] = previous
        os.close(fd)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        if OUT.exists(): (OUT / 'stopped.json').write_text(json.dumps(dict(error=str(error), transactionWrites=0, VMStarts=0), indent=2) + '\n')
        raise

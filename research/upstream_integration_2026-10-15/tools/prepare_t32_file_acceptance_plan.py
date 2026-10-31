#!/usr/bin/env python3
"""Freeze the prepared candidate, complete backup and an unapproved offline plan."""
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence
WORK=ROOT/'.build/t32-t33-completion-20261023'


def main():
    candidate=json.loads(evidence.read(WORK/'candidate.json'))
    backup=json.loads(evidence.read(WORK/'acceptance-backup.json'));vm=Path(backup['vm'])
    files={}
    def freeze(path):files[str(path)]=evidence.digest(path)
    for path in Path(candidate['bundle']).rglob('*'):
        if path.is_symlink():raise ValueError('Linked candidate input')
        if path.is_file():freeze(path)
    for name in ('acceptance-backup.json','candidate.json',Path(candidate['archive']).name,
                 'file-originals-readonly.json','file-audit-final.log','file-normal-detach.log','acceptance-guards.log'):
        freeze(WORK/name)
    for name in ('execute_t32_file_acceptance.py','prepare_t32_file_acceptance_plan.py',
                 'prepare_t32_completion_backup.py','test_t32_file_acceptance.py'):
        freeze(Path(__file__).parent/name)
    for name in ('cfw_verify_effects.py','cfw_disk_txn.py','cfw_guest_evidence.py','vm_lock.py','sparse_file.py'):
        freeze(ROOT/'scripts'/name)
    for path in (ROOT/'scripts/patchers').glob('*.py'):freeze(path)
    python=ROOT/'.venv/bin/python';freeze(python.resolve(strict=True))
    freeze(ROOT/'.venv/pyvenv.cfg')
    plan=dict(schemaVersion=1,approvalRequired=True,approved=False,
        scope='T32 stopped VM: fresh regular/classic CFW publication, complete-file Undo for three named Mach-O files, reapplication and independent readonly checks',
        vm=str(vm),generationID='6ebc5f6705cf0bffb32da62bf3006cc7ece5027edee4306abc8031aee9f4bb42',
        expectedCurrentImageSHA256=backup['files']['Disk.img']['sha256'],backup=backup['backup'],
        candidateVersion=candidate['version'],candidateArchive=candidate['archive'],archiveSHA256=candidate['archiveSHA256'],
        cliExecutable=str(Path(candidate['bundle'])/'Contents/MacOS/vphone-cli'),python=str(python),pythonResolved=str(python.resolve(strict=True)),
        invokerUID=501,invokerGID=20,
        declarations=['system-seputil-boot-gigalocker_uuid','system-launchd_cache_loader-boot-unsecure_cache_gate',
                      'system-mobileactivationd-boot-should_hactivate'],
        targets=['system:/usr/libexec/seputil','system:/usr/libexec/launchd_cache_loader','system:/usr/libexec/mobileactivationd'],
        phases=[dict(name='on',operation='one regular/classic CFW install with explicit Cryptex reinstall on a full disk clone'),
                dict(name='off',operation='one transaction undoing exactly the three named declarations on a full disk clone'),
                dict(name='reapplied',operation='one regular/classic CFW install with explicit Cryptex reinstall on a full disk clone')],
        acceptance=['Strict final output bytes and mode/uid/gid at every publication; no AA.gl exception',
                    'Original source qualification and all CodeDirectory pages, including independent actual restored file readback',
                    'Reapplied file contents and mode/uid/gid exactly match the first new on publication',
                    'Same journal seals disk, file-original catalog, blobs, final output and component receipt'],
        oldMismatch='Keep the old v4 AA.gl mismatch and old baseline untouched; a new actual CFW producer establishes a separate new publication',
        preserve=['Complete current disk and 12-member boot-state backup','Every prior generation and history',
                  'Original Mach-O backups','Other VMs including protected PID33355 and PID61974'],
        temporaryCleanup='Only new invocation staging, decoded source images after normal detach and ordinary installer temporary paths; retain old disks, originals, histories and failed transaction evidence',
        noForceUnmount=True,automaticRetry=False,automaticRollback=False,
        failurePolicy='Stop remaining phases; retain active state and transaction evidence, no VM boot and no inferred rollback',
        VMStarts=0,securityWindows=0,BundleStoreInstall=False,VMRebind=False,
        guestOriginQualified=False,runtimeValidated=False,completeT32T33Acceptance=False,
        subsequentWork='Trusted guest producer/origin bridge and a separately prepared GUI/runtime window remain pending',
        frozenInputs=files)
    destination=WORK/'file-acceptance-plan.json';evidence.write_new(destination,json.dumps(plan,indent=2).encode()+b'\n')
    print(json.dumps(dict(plan=str(destination),sha256=evidence.digest(destination),candidate=candidate['version'],
                         candidateArchiveSHA256=candidate['archiveSHA256'],frozenFiles=len(files),backupFiles=len(backup['files']))))


if __name__=='__main__':main()

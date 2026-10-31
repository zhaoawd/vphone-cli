#!/usr/bin/env python3
"""Freeze a new, unapproved continuation after the external-mount assertion fix."""
import json
from pathlib import Path
import stat
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t32-t33-completion-20261023'
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_guest_evidence as evidence


def main():
    candidate_path = WORK / 'candidate-package-r6.json'
    candidate = json.loads(evidence.read(candidate_path))
    old = json.loads(evidence.read(WORK / 'fresh-file-acceptance-plan.json'))
    result = json.loads(evidence.read(WORK / 'fresh-offline-acceptance/result.json'))
    preservation = json.loads(evidence.read(WORK / 'fresh-original-preservation.json'))
    backup = json.loads(evidence.read(WORK / 'acceptance-backup.json'))
    if (result['state'] != 'failed' or result['phases'] or not preservation['all12OriginalPersistentFilesUnchanged']
            or not preservation['all10FreshBootFilesMatchBackup'] or preservation['unfinishedTransactions']):
        raise ValueError('Prior isolated attempt is not a preserved pre-publication failure')
    vm = Path(old['vm'])
    frozen = {}
    def add(path):
        if path.is_symlink():
            raise ValueError('Linked execution input')
        frozen[str(path)] = evidence.digest(path)
    for path in Path(candidate['bundle']).rglob('*'):
        if path.is_symlink():
            raise ValueError('Linked candidate')
        if path.is_file():
            add(path)
    add(candidate_path)
    add(Path(candidate['archive']))
    for name in ('acceptance-backup.json', 'fresh-original-preservation.json', 'fresh-failure-cleanup.json',
                 'fresh-frozen-inputs-after-execution.json', 'fresh-offline-acceptance/result.json',
                 'fresh-offline-acceptance/generation-prepare.log', 'fresh-offline-acceptance/on.log',
                 'external-mount-red.log', 'external-mount-green.log', 'external-mount-related.log',
                 'resumed-acceptance-guards.log'):
        add(WORK / name)
    for name in ('execute_t32_resumed_file_acceptance.py', 'execute_t32_file_acceptance.py',
                 'test_t32_resumed_file_acceptance.py', 'prepare_t32_resumed_acceptance_plan.py'):
        add(Path(__file__).parent / name)
    for name in ('cfw_disk_txn.py', 'cfw_guest_evidence.py', 'cfw_verify_effects.py', 'vm_lock.py',
                 'sparse_file.py', 'lib/cfw_common.sh'):
        add(ROOT / 'scripts' / name)
    for path in (ROOT / 'scripts/patchers').glob('*.py'):
        add(path)
    python = ROOT / '.venv/bin/python'
    add(python.resolve(strict=True))
    add(ROOT / '.venv/pyvenv.cfg')
    fresh_identity = {}
    for name in old['copyBootFiles']:
        info = (vm / name).lstat()
        fresh_identity[name] = dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size,
                                    mtime_ns=info.st_mtime_ns, mode=stat.S_IMODE(info.st_mode),
                                    uid=info.st_uid, gid=info.st_gid)
    plan = dict(schemaVersion=1, approved=False, approvalRequired=True,
        scope='One separately approved three-Mach-O on/off/on continuation on the retained fresh-generation copy',
        priorPlanSHA256='f3eabf4a9210e26eeeaeb2da433a42963848d1c9c908f3d50119dd7a74d0cedf',
        priorResult='fresh generation prepared; external mount assertion refused first install before publication',
        vm=str(vm), sourceVM=old['sourceVM'], generationID=result['generationID'],
        expectedPlanSHA256=old['expectedPlanSHA256'], archiveSHA256=old['archiveSHA256'],
        desiredQualification='Reopen actual root-owned desired record and verify generation, semantic plan and archive association; formal CLI requalifies complete generation and disk identity',
        candidateVersion=candidate['version'], candidateArchive=candidate['archive'],
        candidateArchiveSHA256=candidate['archiveSHA256'],
        cliExecutable=str(Path(candidate['bundle']) / 'Contents/MacOS/vphone-cli'),
        python=str(python), pythonResolved=str(python.resolve(strict=True)),
        originalBootSHA256={name: row['sha256'] for name, row in backup['files'].items()},
        originalBootIdentity={name: dict(row['sourceIdentity'], mode=row['mode'], uid=row['uid'], gid=row['gid'])
                              for name, row in backup['files'].items()},
        freshBootSHA256={name: row['sha256'] for name, row in preservation['freshFiles'].items()},
        freshBootIdentity=fresh_identity, declarations=old['declarations'], targets=old['targets'],
        phases=['one regular/classic Cryptex reapplication', 'one exact three-declaration Undo',
                'one regular/classic Cryptex reapplication'], checks=old['checks'],
        mountRootPolicy='Keep /private/tmp; external path requires live plan, VM lock and exact journal directory identity',
        sourceCachePolicy='Reuse only generation/digest-qualified Cryptex caches in this fresh copy',
        temporaryCleanup='Allow standard CFW cleanup of this fresh copy .cfw_temp (including regenerable caches from its failed attempt), and only new staging/decoded scratch after normal detach',
        preserve=['Original VM and all12 persistent inputs', 'Complete backup and all old disks/originals/history',
                  'Fresh generation and first failed journal/evidence', 'Other VMs'],
        VMStarts=0, securityWindows=0, BundleStoreInstall=False, VMRebind=False,
        newGeneration=False, newVMClone=False, noForceUnmount=True,
        automaticRetry=False, automaticRollback=False, failurePolicy='Stop remaining phases and preserve evidence',
        originQualified=False, runtimeValidated=False, completeT32T33Acceptance=False, frozenInputs=frozen)
    destination = WORK / 'resumed-file-acceptance-plan.json'
    evidence.write_new(destination, json.dumps(plan, indent=2).encode() + b'\n')
    print(json.dumps(dict(plan=str(destination), sha256=evidence.digest(destination),
                         frozenFiles=len(frozen), candidate=candidate['version'], archiveSHA256=candidate['archiveSHA256'])))


if __name__ == '__main__':
    main()

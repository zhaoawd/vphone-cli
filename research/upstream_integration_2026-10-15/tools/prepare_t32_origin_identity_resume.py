#!/usr/bin/env python3
"""Prepare a concrete follow-up plan only after the previous run has stopped."""
import copy
import json
import os
from pathlib import Path
import stat
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t32-t33-completion-20261023'
PRIOR = WORK / 'producer-acceptance-20261024'
OUT = WORK / 'origin-identity-acceptance-20261024-r2'
OLD_SHA = 'd5cc7bf5b0ce1d0e0159985e62acc618f2d59aabd4a020b381dfb6a4bebd565b'
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_guest_evidence as evidence
import cfw_disk_txn as txn
import cfw_verify_effects as audit


def load(path):
    return json.loads(evidence.read(path))


def stopped_result():
    path = PRIOR / 'execution/result.json'
    if not path.exists():
        raise ValueError('Previous approved execution has not finished; no follow-up plan created')
    result = load(path)
    if (result.get('state') != 'failed' or result.get('targetAttachments') != []
            or result.get('baseline') != dict(files=10, fullReadbackPassed=True)
            or 'preservationOrCleanupError' in result):
        raise ValueError('Previous result requires a separate preservation or cleanup investigation')
    off = PRIOR / 'execution/regular/off.log'
    if not off.exists() or 'VM/generation/disk identity mismatch' not in off.read_text():
        raise ValueError('Previous failure is not the reproduced native identity refusal')
    return result


def boot_snapshot(vm, names):
    rows = {}
    with audit.locked_vm(vm):
        txn.require_unheld(vm / 'Disk.img', os.getpid(), 'follow-up preparation disk')
        for name in names:
            path = vm / name
            before = path.lstat()
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise ValueError('Boot input is linked or special: ' + name)
            rows[name] = dict(sha256=evidence.digest(path), bytes=before.st_size,
                dev=before.st_dev, ino=before.st_ino, mtime_ns=before.st_mtime_ns,
                mode=stat.S_IMODE(before.st_mode), uid=before.st_uid, gid=before.st_gid)
            after = path.lstat()
            fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_uid', 'st_gid', 'st_nlink')
            if any(getattr(before, key) != getattr(after, key) for key in fields):
                raise ValueError('Boot input changed during preparation: ' + name)
    return rows


def main():
    stopped_result()
    if OUT.exists():
        raise ValueError('Preserve an existing follow-up preparation')
    if evidence.digest(PRIOR / 'offline-plan.json') != OLD_SHA:
        raise ValueError('Previous approved plan changed')
    old = load(PRIOR / 'offline-plan.json')
    candidate = load(WORK / 'candidate-origin-identity-package-20261024.json')
    if (candidate['version'] != '2.6.2-local.a84f5889b159'
            or candidate['archiveSHA256'] != 'c7a6e66a6848dc92eb7e8f3680ec374c9cf01e9482e5c1ea55660a7db2c88105'
            or evidence.digest(Path(candidate['archive'])) != candidate['archiveSHA256']):
        raise ValueError('Follow-up candidate differs from the tested package')
    first = load(PRIOR / 'execution/regular/on.json')
    if (first['independentAudit']['passed'] is not True
            or first['sourceReceipt']['originQualified'] is not True):
        raise ValueError('Existing first on state lacks independent source/effect acceptance')
    regular, experimental = copy.deepcopy(old['targets'])
    vm = Path(regular['vm'])
    if Path(experimental['vm']).exists() or Path(experimental['firstBindingBackup']).exists():
        raise ValueError('Experimental target already exists; preserve it')
    snapshot = boot_snapshot(vm, regular['copyBootFiles'])
    if snapshot['Disk.img']['sha256'] != first['independentAudit']['currentImageSHA256']:
        raise ValueError('Existing regular disk differs from the independently audited first on state')
    archive = vm / '.cfw-history' / first['transactionID']
    desired = archive / 'guest-plan.json'
    binding = load(vm / 'launchpad.json')
    if binding != first['binding'] or binding['bundle'] != old['candidate']['version']:
        raise ValueError('Existing regular binding changed')
    old_cli = old['targets'][0]['installCommand'][0]
    new_cli = str(Path(old_cli).parents[3].parent / candidate['version'] / 'VPhone.bundle/Contents/MacOS/vphone-cli')
    for target in (regular, experimental):
        for key in ('installCommand', 'undoCommand', 'generationCommand'):
            target[key] = [new_cli if arg == old_cli else arg for arg in target[key]]
    regular.update(mode='reuse-existing-generation', generationID=first['generationID'],
        expectedDesiredSHA256=evidence.digest(desired), expectedBinding=binding,
        currentBootFiles=snapshot, beforeWriteBackup=str(WORK / 't32q-origin-identity-before-20261024'),
        beforeWriteBackupFiles=regular['copyBootFiles'] + ['launchpad.json', '.firmware-desired-plan.json'])
    if Path(regular['beforeWriteBackup']).exists() or Path(new_cli).parents[3].exists():
        raise ValueError('Preserve an existing follow-up backup or Store version')
    regular.pop('generationCommand')
    regular['undoCommand'] = [first['generationID'] if arg == '<verified-new-generation-id>' else arg
                              for arg in regular['undoCommand']]
    experimental['mode'] = 'fresh-copy-and-generation'
    local_cli = Path(candidate['bundle']) / 'Contents/MacOS/vphone-cli'
    frozen = dict(old['frozenInputs'])
    frozen[str(Path(candidate['archive']))] = candidate['archiveSHA256']
    for path in Path(candidate['bundle']).rglob('*'):
        if path.is_file():
            frozen[str(path)] = evidence.digest(path)
    for path in (Path(__file__), PRIOR / 'execution/result.json', PRIOR / 'execution/regular/on.json', desired):
        frozen[str(path.resolve(strict=True))] = evidence.digest(path)
    plan = {key: copy.deepcopy(old[key]) for key in ('sourceBackup', 'sourceBootFiles', 'pythonRuntime',
        'minimumInitialFreeBytes', 'minimumEachCFWFreeBytes')}
    available = os.statvfs(ROOT)
    plan.update(schemaVersion=1, scope='T32/T33 offline continuation with native source-checkpoint compatibility fix',
        supersedesUnapprovedDraftSHA256='437f30eac4e57709298335d2e6cb4608595fdf2f5ea9721f873cfaa8cd040e93',
        priorPlanSHA256=OLD_SHA, priorFailurePreserved=True, candidate={key: candidate[key] for key in (
            'version', 'bundle', 'archive', 'archiveSHA256', 'archiveBytes', 'cliSHA256', 'vmSHA256')},
        targets=[regular, experimental], frozenInputs=frozen, VMStarts=0, normalGUIBoots=0, securityWindows=0,
        automaticRetry=False, automaticRollback=False, reuseLockedPythonRuntime=True,
        initialCapacityPassed=available.f_bavail * available.f_frsize >= old['minimumInitialFreeBytes'],
        observedAvailableBytes=available.f_bavail * available.f_frsize,
        preserve=['original VM', 'all old disks and source files', 'all backups and histories',
                  'existing regular generation and first on evidence', 'other VMs'],
        cleanup=['only new transaction scratch', 'regular target rebuildable .cfw_temp through formal CFW'],
        signatureAcceptance='new candidate first on -> whole-file Undo -> exact first-on bytes and metadata',
        sourceAcceptance='same-journal source, attestation, receipts and binding; no legacy source upgrade',
        installCommand=[str(local_cli), 'core-bundle', 'install', '--version', candidate['version'],
                        '--archive', candidate['archive'], '--sha256', candidate['archiveSHA256']],
        verifyCommand=[new_cli, 'core-bundle', 'verify', '--version', candidate['version']],
        regularBindingCommand=[new_cli, 'vm', 'bind-core-bundle', vm.name, '--library-root', str(vm.parent),
                               '--version', candidate['version']],
        authorization='not approved; new candidate installation and another on/off/on execution require explicit approval')
    OUT.mkdir()
    evidence.write_new(OUT / 'offline-plan.json', json.dumps(plan, ensure_ascii=False, indent=2).encode() + b'\n')
    print(json.dumps(dict(state='prepared-not-approved', plan=str(OUT / 'offline-plan.json'),
        planSHA256=evidence.digest(OUT / 'offline-plan.json'), initialCapacityPassed=plan['initialCapacityPassed'])))


if __name__ == '__main__':
    main()

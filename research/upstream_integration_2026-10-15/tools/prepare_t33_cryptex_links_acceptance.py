#!/usr/bin/env python3
"""Prepare a named EXP-only continuation after the failed run was finalized."""
import copy
import hashlib
import json
import os
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
BASE=ROOT/'.build/t32-t33-completion-20261023'
PRIOR=BASE/'origin-identity-acceptance-20261024-r2'
OUT=BASE/'exp-cryptex-links-acceptance-20261024'


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        while block:=stream.read(1<<20):h.update(block)
    return h.hexdigest()


def load(path):return json.loads(Path(path).read_text())


def main():
    final=load(PRIOR/'continuation-finalization.json');native=load(PRIOR/'execution/result.json')
    if (final['nativeState']!='failed' or final['preservation']['targetAttachments']!=[]
            or native.get('regularBeforeWriteBackupVerified') is not True
            or 'preservationOrCleanupError' in native):
        raise ValueError('Prior failure has not completed preservation checks')
    old=load(PRIOR/'offline-plan.json');candidate=load(BASE/'candidate-exp-cryptex-links-package-20261024-r3.json')
    snapshot=load(OUT/'current-target-snapshot.json')
    if sha(candidate['archive'])!=candidate['archiveSHA256'] or not candidate['cliExecutableContentUnchanged']:
        raise ValueError('Tested repair candidate differs')
    target=copy.deepcopy(old['targets'][1]);old_cli=target['installCommand'][0]
    new_cli=str(Path(old_cli).parents[3].parent/candidate['version']/'VPhone.bundle/Contents/MacOS/vphone-cli')
    for key in ('installCommand','undoCommand'):
        target[key]=[new_cli if arg==old_cli else snapshot['generationID'] if arg=='<verified-new-generation-id>' else arg
                     for arg in target[key]]
    for key in ('generationCommand','firstBindingBackup','cloneFrom','exclude'):target.pop(key,None)
    target.update(generationID=snapshot['generationID'],newGeneration=False,
        mode='reuse-failed-unpublished-generation',phases=['verified fourteen-file pre-write backup',
        'qualified first install','independent readonly audit and source receipt',
        'two-plist declaration Undo','independent complete originals readback',
        'qualified reapplication','independent exact first-on bytes and metadata'])
    vm=Path(target['vm']);history=vm/'.cfw-history/20261024T131058Z-8sbOtt6f'
    failed=load(history/'transaction.json')
    if failed['status']!='failed' or failed['original_check']['unchanged'] is not True:
        raise ValueError('Failed EXP transaction changed')
    frozen=dict(old['frozenInputs'])
    for path in Path(candidate['bundle']).rglob('*'):
        if path.is_file():frozen[str(path)]=sha(path)
    additional=[Path(candidate['archive']),Path(__file__),OUT/'current-target-snapshot.json',
        PRIOR/'offline-plan.json',PRIOR/'execution/result.json',PRIOR/'continuation-finalization.json',
        PRIOR/'execution/regular/reapplied.json',PRIOR/'execution/regular/transition.json',
        history/'transaction.json',history/'guest-file-originals.json',
        BASE/'candidate-exp-cryptex-links-package-20261024-r3.json']
    for path in additional:frozen[str(path.resolve())]=sha(path)
    unrelated=load(PRIOR/'unrelated-disk-identities-before.json')
    regular=ROOT/'.build/t32q-20261024/Disk.img';s=regular.stat()
    unrelated[str(regular.relative_to(ROOT))]=dict(dev=s.st_dev,ino=s.st_ino,size=s.st_size)
    available=os.statvfs(ROOT);capacity=available.f_bavail*available.f_frsize
    plan={key:copy.deepcopy(old[key]) for key in ('sourceBackup','sourceBootFiles','pythonRuntime')}
    plan.update(schemaVersion=1,scope='T33 EXP-only continuation after contained Cryptex hard-link reader repair',
        priorPlanSHA256=final['planSHA256'],priorFinalizationManifestSHA256=final['archiveManifestSHA256'],
        priorFailurePreserved=True,regularStrictAcceptancePreserved=True,
        candidate={key:candidate[key] for key in ('version','bundle','archive','archiveSHA256','archiveBytes','cliSHA256','vmSHA256')},
        targets=[target],currentTargetSnapshot=snapshot,unrelatedDiskIdentities=unrelated,
        preWriteBackup=str(BASE/'t33q-cryptex-links-before-20261024'),
        expectedBinding=load(vm/'launchpad.json'),minimumInitialFreeBytes=50*(1<<30),
        minimumEachCFWFreeBytes=50*(1<<30),observedAvailableBytes=capacity,
        initialCapacityPassed=capacity>=50*(1<<30),frozenInputs=frozen,
        VMStarts=0,normalGUIBoots=0,securityWindows=0,automaticRetry=False,automaticRollback=False,
        reuseLockedPythonRuntime=True,authorization='not approved; new candidate and new EXP execution require explicit approval',
        privateDesiredPreparationLimit='Expected digest captured by prior native originals index; fresh root full readback before backup/install is mandatory',
        backupAcceptance='all fourteen files fully read and cloned with bytes and metadata verification before any install or binding change; final full backup readback',
        preserve=['regular T32 accepted disk and all phases','original VM','all old disks, originals, backups and history',
                  'existing EXP generation and failed transaction','both current EXP cache files in fourteen-file backup','other VMs'],
        cleanup=['only new transaction scratch after normal unmount',
                 'EXP .cfw_temp rebuildable cache through formal CFW only after both existing files are fully backed up'],
        signatureAcceptance='complete original restoration and exact first/reapplied file bytes plus mode/uid/gid; no normalized-byte substitution',
        runtimeProbeCommand=[str(Path(old['pythonRuntime']['venv'])/'bin/python3'),
            str(Path(candidate['bundle'])/'Contents/Resources/scripts/check_python_runtime.py'),'--locked','--json'],
        installCommand=[str(Path(candidate['bundle'])/'Contents/MacOS/vphone-cli'),'core-bundle','install',
            '--version',candidate['version'],'--archive',candidate['archive'],'--sha256',candidate['archiveSHA256']],
        verifyCommand=[new_cli,'core-bundle','verify','--version',candidate['version']],
        bindingCommand=[new_cli,'vm','bind-core-bundle',vm.name,'--library-root',str(vm.parent),'--version',candidate['version']])
    with (OUT/'offline-plan.json').open('x') as output:json.dump(plan,output,ensure_ascii=False,indent=2);output.write('\n')
    print(json.dumps(dict(state='prepared-not-approved',plan=str(OUT/'offline-plan.json'),
        planSHA256=sha(OUT/'offline-plan.json'),frozenInputs=len(frozen),initialCapacityPassed=plan['initialCapacityPassed'])))


if __name__=='__main__':main()

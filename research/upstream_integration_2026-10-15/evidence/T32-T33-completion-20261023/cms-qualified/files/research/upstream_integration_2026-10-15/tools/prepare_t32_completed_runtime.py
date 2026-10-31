#!/usr/bin/env python3
"""Back up the completed isolated target and prepare, but never approve or boot."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
TOOLS = Path(__file__).parent
PREVIOUS = ROOT / '.build/t32-t33-completion-20261023'
WORK = PREVIOUS / 'completed-runtime'
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_guest_evidence as evidence
import cfw_disk_txn as transaction
import cfw_verify_effects as audit


def write(path, value):
    evidence.write_new(path, json.dumps(value, indent=2).encode() + b'\n')


def main():
    if sys.argv[1:] not in (['--prepare-only'], ['--wait-and-prepare-only'], ['--prepare-qualified-only']):
        raise ValueError('Preparation only; no runtime execution entrypoint')
    if sys.argv[1:] == ['--wait-and-prepare-only']:
        deadline = time.monotonic() + 24 * 60 * 60
        while True:
            observed = json.loads(evidence.read(PREVIOUS / 'resumed-finalization.json'))
            if observed['state'] == 'offline-acceptance-finalized':
                break
            if observed['state'] in ('finalization-stopped', 'native-failure-archived'):
                raise ValueError('Offline finalization stopped; no runtime backup or plan created')
            if time.monotonic() >= deadline:
                raise ValueError('Preparation wait expired; no VM operation was started')
            time.sleep(2)
    final = json.loads(evidence.read(PREVIOUS / 'resumed-finalization.json'))
    qualified_path = PREVIOUS / 'qualified-signature-reapplication.json'
    qualification = None
    if sys.argv[1:] == ['--prepare-qualified-only']:
        qualification = json.loads(evidence.read(qualified_path))
        if (final['state'] != 'native-failure-archived'
                or qualification['state'] != 'signature-time-qualified-reapplication'
                or qualification['nativeAcceptanceResultChanged'] is not False
                or qualification['currentDiskPublicationVerified'] is not True):
            raise ValueError('Independent signature qualification required; native failure must remain')
    elif final['state'] != 'offline-acceptance-finalized' or final['offlineAcceptancePassed'] is not True:
        raise ValueError('Completed and independently finalized offline acceptance required')
    if evidence.digest(Path(final['archive'])) != final['archiveSHA256']:
        raise ValueError('Completed offline archive differs')
    native = json.loads(evidence.read(PREVIOUS / 'resumed-file-acceptance-plan.json'))
    phase = (dict(audit=dict(currentImageSHA256=qualification['publicationSHA256']),
                  generationID=qualification['generationID'], transactionID=qualification['transactionID'])
             if qualification else json.loads(evidence.read(PREVIOUS / 'resumed-offline-acceptance/reapplied.json')))
    if qualification and qualification['VM'] != native['vm']:
        raise ValueError('Qualified VM differs')
    vm = Path(native['vm'])
    expected = phase['audit']['currentImageSHA256']
    old_work = ROOT / '.build/t32-t33-followup-20261023'
    prior_plan = json.loads(evidence.read(old_work / 'runtime-plan.json'))
    binary = Path(prior_plan['vmExecutable'])
    if evidence.digest(binary) != prior_plan['vmSHA256']:
        raise ValueError('Pinned runtime binary differs')
    signature = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(binary)],
                               capture_output=True, text=True, check=True)
    if 'CDHash=' + prior_plan['CDHash'] not in signature.stderr.splitlines():
        raise ValueError('Pinned runtime CDHash differs')
    config = plistlib.loads(evidence.read(vm / 'config.plist'))
    names = [config['diskImage'], config['nvramStorage'], config['sepStorage'], *config['romImages'].values()]
    for name in names:
        if Path(name).is_absolute() or len(Path(name).parts) != 1 or name not in native['freshBootSHA256']:
            raise ValueError('Boot input does not resolve inside this isolated target: ' + name)
        if (vm / name).is_symlink():
            raise ValueError('Linked boot input')
    with audit.locked_vm(vm):
        transaction.require_unheld(vm / 'Disk.img', os.getpid(), 'runtime preparation disk')
        if evidence.digest(vm / 'Disk.img') != expected:
            raise ValueError('Completed publication changed')
        WORK.mkdir(mode=0o700)
        backup = WORK / 'pre-runtime-backup'
        backup.mkdir(mode=0o700)
        files = {}
        for name in sorted(native['freshBootSHA256']):
            source, target = vm / name, backup / name
            fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                before = os.fstat(fd)
                if name == 'Disk.img':
                    transaction.clone_file(fd, target)
                    shutil.copystat(source, target)
                    digest = expected
                else:
                    shutil.copy2(source, target)
                    digest = evidence.digest(source)
                if evidence.digest(target) != digest:
                    raise ValueError('Runtime backup differs: ' + name)
                evidence.unchanged(source, fd, before)
                files[name] = dict(sha256=digest, bytes=before.st_size,
                    sourceIdentity=evidence.image_identity(before), mode=before.st_mode & 0o7777,
                    uid=before.st_uid, gid=before.st_gid)
            finally:
                os.close(fd)
        write(WORK / 'runtime-backup.json', dict(schemaVersion=1, state='verified-backup',
            vm=str(vm), backup=str(backup), files=files, generationID=phase['generationID'],
            transactionID=phase['transactionID'], restoreAuthorized=False,
            VMWritten=False, VMStarted=False, securityWindowStarted=False))
        info = (vm / 'Disk.img').stat()
        image_identity = dict(evidence.image_identity(info), ctime_ns=info.st_ctime_ns)
    window = WORK / 'boot-window'
    window.mkdir(mode=0o700)
    source = evidence.read(old_work / 'boot-window/scoped-amfidont.py').decode()
    old_path = str(old_work / 'boot-window')
    if source.count(old_path) != 1:
        raise ValueError('Scoped helper path substitution is ambiguous')
    evidence.write_new(window / 'scoped-amfidont.py', source.replace(old_path, str(window)).encode())
    wrappers = []
    for module in ('observe_t32_runtime', 'start_t32_observation_window'):
        path = WORK / (module + '.py')
        source = ('import importlib.util\nfrom pathlib import Path\n'
                  f'spec=importlib.util.spec_from_file_location("completed_runtime_{module}",{str(TOOLS / (module + ".py"))!r})\n'
                  'module=importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n'
                  f'module.WORK=Path({str(WORK)!r})\n'
                  'if __name__=="__main__":raise SystemExit(module.main())\n')
        evidence.write_new(path, source.encode())
        wrappers.append(path)
    frozen_paths = set(native['frozenInputs']) | set(prior_plan['frozenTools'])
    frozen_paths -= {str(old_work / 'boot-window/scoped-amfidont.py')}
    if qualification:
        frozen_paths.add(str(qualified_path))
        frozen_paths |= {str(TOOLS / name) for name in ('qualify_t32_cms_reapplication.py',
            'verify_t32_cms_reapplication.py', 'test_t32_cms_reapplication.py')}
        frozen_paths.add('/usr/bin/openssl')
    frozen_paths |= {str(path) for path in wrappers + [window / 'scoped-amfidont.py', Path(__file__).resolve()]}
    frozen = {path: evidence.digest(Path(path)) for path in sorted(frozen_paths)}
    plan = dict(prior_plan)
    plan.update(scope='One GUI/hash observation on the finalized isolated three-Mach-O target',
        approved=False, vm=str(vm), expectedDiskIdentity=image_identity,
        expectedCurrentImageSHA256=expected, backup=str(backup),
        backupManifestSHA256=evidence.digest(WORK / 'runtime-backup.json'), frozenTools=frozen,
        generationID=phase['generationID'], transactionID=phase['transactionID'],
        priorOfflineArchive=str(final['archive']), priorOfflineArchiveSHA256=final['archiveSHA256'],
        runtimeObserver=str(wrappers[0]), rootWindowStarter=str(wrappers[1]),
        knownLimitation='Prior AA.gl file_get returned EPERM; preserve that failure while independently observing display',
        sourceVMWritten=False, trustedGuestOriginQualified=False)
    plan.update(priorExactWholeFileAcceptancePassed=final['offlineAcceptancePassed'],
                signatureTimeQualification=(str(qualified_path) if qualification else None),
                signatureTimeQualificationSHA256=(evidence.digest(qualified_path) if qualification else None),
                qualificationProfile=('exact-original-restoration-and-cryptographically-verified-CMS-time-difference'
                                      if qualification else 'exact-whole-file-reapplication'))
    write(WORK / 'runtime-plan.json', plan)
    print(json.dumps(dict(state='runtime-plan-prepared-not-approved',
        plan=str(WORK / 'runtime-plan.json'), planSHA256=evidence.digest(WORK / 'runtime-plan.json'),
        completeBootBackupFiles=len(files), frozenTools=len(frozen), VMStarts=0, securityWindows=0)))


if __name__ == '__main__':
    main()

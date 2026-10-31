#!/usr/bin/env python3
"""Back up the stopped diagnostic VM and freeze a new, unapproved display plan."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
TOOLS = Path(__file__).parent
BASE = ROOT / '.build/t32-t33-completion-20261023'
PREVIOUS = BASE / 'short-runtime'
WORK = BASE / 'display-runtime'
ARCHIVE = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/short-runtime-outcome/manifest.json'
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_guest_evidence as evidence
import cfw_disk_txn as transaction
import cfw_verify_effects as audit
from t32_runtime_preflight import validate_control_socket


def save(path, value):
    evidence.write_new(path, json.dumps(value, indent=2).encode() + b'\n')


def main():
    if sys.argv[1:] != ['--prepare-only']:
        raise ValueError('Preparation only; no approval or execution')
    if WORK.exists():
        raise ValueError('Preserve existing preparation')
    if evidence.digest(ARCHIVE) != 'ccb1bc0aadad1ed8dbe47022c699731ea6f9471ed827ad734cceebb7bc3a6df7':
        raise ValueError('Consumed runtime archive changed')
    archive = json.loads(evidence.read(ARCHIVE))
    for row in archive['files']:
        if evidence.digest(ARCHIVE.parent / row['path']) != row['sha256']:
            raise ValueError('Archived runtime input changed')
    safety = json.loads(evidence.read(PREVIOUS / 'runtime-safety.json'))
    if not safety['passed'] or not safety['normalShutdownVerified']:
        raise ValueError('Prior normal shutdown and cleanup required')
    prior = json.loads(evidence.read(PREVIOUS / 'runtime-plan.json'))
    vm = Path(prior['vm'])
    geometry = validate_control_socket(vm)
    binary = Path(prior['vmExecutable'])
    if evidence.digest(binary) != prior['vmSHA256']:
        raise ValueError('Pinned executable changed')
    signature = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(binary)],
                               capture_output=True, text=True, check=True)
    if 'CDHash=' + prior['CDHash'] not in signature.stderr.splitlines():
        raise ValueError('Pinned CDHash changed')
    names = json.loads(evidence.read(PREVIOUS / 'runtime-backup.json'))['files']
    config = plistlib.loads(evidence.read(vm / 'config.plist'))
    for name in [config['diskImage'], config['nvramStorage'], config['sepStorage'], *config['romImages'].values()]:
        if Path(name).is_absolute() or len(Path(name).parts) != 1 or name not in names:
            raise ValueError('Boot input escapes diagnostic VM')
    with audit.locked_vm(vm):
        transaction.require_unheld(vm / 'Disk.img', os.getpid(), 'display preparation disk')
        WORK.mkdir(mode=0o700)
        backup = WORK / 'pre-runtime-backup'
        backup.mkdir(mode=0o700)
        files = {}
        for name in sorted(names):
            source, target = vm / name, backup / name
            fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                before = os.fstat(fd)
                if name == 'Disk.img':
                    transaction.clone_file(fd, target)
                    shutil.copystat(source, target)
                else:
                    shutil.copy2(source, target)
                digest = evidence.digest(source)
                if evidence.digest(target) != digest or target.stat().st_ino == before.st_ino:
                    raise ValueError('Independent full backup differs: ' + name)
                evidence.unchanged(source, fd, before)
                files[name] = dict(sha256=digest, bytes=before.st_size,
                    sourceIdentity=evidence.image_identity(before), mode=before.st_mode & 0o7777,
                    uid=before.st_uid, gid=before.st_gid)
                print('Complete backup verified: ' + name, flush=True)
            finally:
                os.close(fd)
        save(WORK / 'runtime-backup.json', dict(schemaVersion=1, state='verified-backup',
            vm=str(vm), backup=str(backup), files=files, restoreAuthorized=False,
            runtimeSnapshotOnly=True, CFWAuthorityCopied=False))
        info = (vm / 'Disk.img').stat()
        identity = dict(evidence.image_identity(info), ctime_ns=info.st_ctime_ns)
    window = WORK / 'boot-window'
    window.mkdir(mode=0o700)
    helper = evidence.read(PREVIOUS / 'boot-window/scoped-amfidont.py').decode()
    previous = str(PREVIOUS / 'boot-window')
    if helper.count(previous) != 1:
        raise ValueError('Ambiguous helper path')
    evidence.write_new(window / 'scoped-amfidont.py', helper.replace(previous, str(window)).encode())
    wrappers = []
    for name in ('observe_t32_runtime', 'start_t32_observation_window'):
        path = WORK / (name + '.py')
        code = ('import importlib.util\nfrom pathlib import Path\n'
            f'spec=importlib.util.spec_from_file_location("display_{name}",{str(TOOLS / (name + ".py"))!r})\n'
            'module=importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n'
            f'module.WORK=Path({str(WORK)!r})\n'
            'if __name__=="__main__":raise SystemExit(module.main())\n')
        evidence.write_new(path, code.encode())
        wrappers.append(path)
    frozen = set(prior['frozenTools'])
    frozen -= {str(PREVIOUS / 'boot-window/scoped-amfidont.py'),
               str(PREVIOUS / 'observe_t32_runtime.py'), str(PREVIOUS / 'start_t32_observation_window.py')}
    frozen |= {str(p) for p in wrappers + [window / 'scoped-amfidont.py', Path(__file__).resolve(),
        TOOLS / 'test_t32_unlock_isolation.py', TOOLS / 'verify_t32_completed_runtime.py', ARCHIVE,
        BASE / 'unlock-isolation-red.log', BASE / 'unlock-isolation-green.log', BASE / 'runtime-observer-final.log']}
    plan = dict(prior)
    plan.update(scope='One GUI Settings/display diagnostic with independent unlock failure recording',
        approved=False, expectedDiskIdentity=identity, expectedCurrentImageSHA256=files['Disk.img']['sha256'],
        backup=str(backup), backupManifestSHA256=evidence.digest(WORK / 'runtime-backup.json'),
        runtimeObserver=str(wrappers[0]), rootWindowStarter=str(wrappers[1]), socketPreflight=geometry,
        frozenTools={p: evidence.digest(Path(p)) for p in sorted(frozen)},
        previousConsumedRuntimePlanSHA256=evidence.digest(PREVIOUS / 'runtime-plan.json'),
        previousOutcomeArchive=str(ARCHIVE), previousOutcomeArchiveSHA256=evidence.digest(ARCHIVE),
        knownLimitation='AA.gl EPERM and unlock timeout remain failures; independent display must use verified foreground and distinct nonuniform frames',
        sourceVMWritten=False, runtimeSnapshotOnly=True, CFWAuthorityCopied=False,
        observations=['AA.gl SHA-256 only', 'screen.unlock once; retain failure',
                      'independent Preferences transition, verified foreground, two host frames',
                      'normal system.shutdown and exact helper/process cleanup'],
        automaticRetry=False, targetState='same diagnostic copy after one normal shutdown; complete new pre-boot backup',
        VMStarts=1, securityWindows=1)
    save(WORK / 'runtime-plan.json', plan)
    print(json.dumps(dict(state='prepared-not-approved', plan=str(WORK / 'runtime-plan.json'),
        planSHA256=evidence.digest(WORK / 'runtime-plan.json'), backupFiles=len(files),
        frozenTools=len(frozen), socketBytes=geometry['bytesIncludingNul'], VMStarts=0, securityWindows=0)), flush=True)


if __name__ == '__main__':
    main()

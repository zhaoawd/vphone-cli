#!/usr/bin/env python3
"""Cross-check finished offline evidence and preservation without writing VM state."""
import json
from collections import Counter
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t32-t33-completion-20261023'
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_guest_evidence as evidence


def save(name, value):
    evidence.write_new(WORK / name, json.dumps(value, indent=2).encode() + b'\n')


def main():
    plan_path = WORK / 'resumed-file-acceptance-plan.json'
    plan = json.loads(evidence.read(plan_path))
    approval = json.loads(evidence.read(WORK / 'resumed-file-acceptance-approval.json'))
    if approval != dict(approved=True, planSHA256=evidence.digest(plan_path)):
        raise ValueError('Plan approval differs')
    result = json.loads(evidence.read(WORK / 'resumed-offline-acceptance/result.json'))
    if result['state'] != 'resumed-offline-on-off-on-passed':
        raise ValueError('Complete native acceptance did not pass')
    if any(result[field] is not False for field in ('sourceVMWritten', 'VMStarted', 'securityWindowStarted')):
        raise ValueError('Unexpected native scope')
    if [row['name'] for row in result['phases']] != ['on', 'off', 'reapplied'] or not result['transition']['passed']:
        raise ValueError('Three complete phases are required')
    vm, source = Path(plan['vm']), Path(plan['sourceVM'])
    phases = {}
    for row in result['phases']:
        phase = json.loads(evidence.read(WORK / 'resumed-offline-acceptance' / (row['name'] + '.json')))
        audit = phase['audit']
        if phase['transactionID'] != row['transactionID'] or phase['generationID'] != plan['generationID']:
            raise ValueError('Phase publication differs')
        if (audit['passed'] is not True or any(x['matches'] is not True for x in audit['targets'])
                or any(x['passed'] is not True for x in audit['codePages'])
                or audit['cleanup'] != dict(mountsReleased=True, imageDetached=True)):
            raise ValueError('Incomplete independent audit')
        if set(phase['targets']) != set(plan['targets']):
            raise ValueError('Different target set')
        phases[row['name']] = phase
    receipt_summaries = {}
    for phase_name, phase in phases.items():
        filename = 'guest-component-receipts.json' if phase_name == 'off' else 'guest-install-receipts.json'
        receipt = json.loads(evidence.read(vm / '.cfw-history' / phase['transactionID'] / filename))
        if receipt['transactionID'] != phase['transactionID'] or receipt['generationID'] != plan['generationID']:
            raise ValueError('Receipt phase binding differs')
        if phase_name == 'off':
            if set(receipt['removedDeclarations']) != set(plan['declarations']):
                raise ValueError('Undo receipt removed different declarations')
            receipt_summaries[phase_name] = dict(removedDeclarations=receipt['removedDeclarations'],
                                                retainedDeclarations=receipt['appliedDeclarations'],
                                                guestOrigin=receipt['guestOrigin'])
        else:
            receipt_summaries[phase_name] = dict(
                declarationStates={row['declarationID']: row['state'] for row in receipt['declarations']},
                stateCounts=dict(Counter(row['state'] for row in receipt['declarations'])),
                originQualified=receipt['originQualified'], runtimeValidated=receipt['runtimeValidated'])
    original_catalog = json.loads(evidence.read(vm / '.cfw-history' / phases['on']['transactionID'] / 'guest-file-originals.json'))
    for target in plan['targets']:
        first = phases['on']['targets'][target]
        restored = phases['off']['targets'][target]
        reapplied = phases['reapplied']['targets'][target]
        if restored != original_catalog['members'][target]['state'] or first == restored or first != reapplied:
            raise ValueError('Complete file transition differs: ' + target)
    # Native executor does the final full content read before reporting success.
    # This independent postcheck checks the same file identities, not a new hash read.
    identities = {}
    for name, expected in plan['originalBootIdentity'].items():
        info = (source / name).lstat()
        identity = dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size,
                        mtime_ns=info.st_mtime_ns, mode=stat.S_IMODE(info.st_mode),
                        uid=info.st_uid, gid=info.st_gid)
        if identity != expected:
            raise ValueError('Original persistent identity differs: ' + name)
        identities[name] = identity
    for directory in (vm, source):
        if any(directory.glob('.cfw_disk.*')) or (directory / '.firmware-desired-pending.json').exists():
            raise ValueError('Unfinished target transaction')
    info = plistlib.loads(subprocess.run(['/usr/bin/hdiutil', 'info', '-plist'],
                         capture_output=True, check=True, timeout=30).stdout)
    attachments = [image.get('image-path', '') for image in info.get('images', [])
                   if any(image.get('image-path', '').startswith(str(directory) + '/') for directory in (vm, source))]
    if attachments:
        raise ValueError('Target image attachment remains: ' + str(attachments))
    expected_processes = json.loads(evidence.read(WORK / 'fresh-failure-cleanup.json'))['processes']
    processes = []
    for expected in expected_processes:
        pid = expected.split(' ', 1)[0]
        actual = subprocess.run(['/bin/ps', '-p', pid, '-o', 'pid=,command='],
                                capture_output=True, text=True, check=True, timeout=10).stdout.strip()
        if actual != expected:
            raise ValueError('Protected process identity differs: ' + pid)
        processes.append(actual)
    for name, expected in plan['frozenInputs'].items():
        if evidence.digest(Path(name)) != expected:
            raise ValueError('Frozen input differs: ' + name)
    history = {row['name']: str(vm / '.cfw-history' / row['transactionID'] / 'Disk.img') for row in result['phases']}
    if any(not Path(path).is_file() for path in history.values()):
        raise ValueError('Retained prior disk is missing')
    save('resumed-preservation.json', dict(
        executorFinalOriginalFullReadbackPassed=True, originalPersistentIdentities=identities,
        independentPostcheckFullContentRead=False, exactThreeFileTransitionsPassed=True,
        retainedPriorDisks=history, componentReceiptSummaries=receipt_summaries, unfinishedTransactions=[], VMStarts=0, securityWindows=0,
        guestOriginQualified=False, runtimeValidated=False, accepted=False))
    save('resumed-cleanup.json', dict(targetAttachments=attachments,
         bothProtectedVMProcessesPresent=True, processes=processes, VMStarts=0, securityWindows=0))
    save('resumed-frozen-inputs-after-execution.json', dict(count=len(plan['frozenInputs']), allDigestsVerified=True))
    print(json.dumps(dict(phaseCount=3, exactThreeFileTransitionsPassed=True,
         originalFileIdentitiesVerified=len(identities), frozenInputsVerified=len(plan['frozenInputs']),
         targetAttachments=[], protectedVMProcesses=2, accepted=False)))


if __name__ == '__main__':
    main()

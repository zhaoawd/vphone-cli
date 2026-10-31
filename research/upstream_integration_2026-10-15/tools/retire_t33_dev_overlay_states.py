"""Retire only four separately approved EXP states, then run one approved continuation."""
import argparse
import gzip
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

import execute_t33_dev_overlay_acceptance as runner
sys.path.insert(0, str(runner.ROOT / 'research'))
import retire_t32_t33_states_20261025 as storage

NAMES = ('.build/t33q-20261024', '.build/t33q-20261024-binding-backup',
         '.build/t33s-20261025', '.build/t32-t33-completion-20261023/t33s-first-binding-20261025')
OUT = runner.WORK / 'retirement'


def configure():
    storage.ROOT = runner.ROOT
    storage.OUT = OUT
    storage.NAMES = NAMES


def validate_scope(plan):
    rows = plan['retirement']['retirementTargets']
    if (tuple(row['path'] for row in rows) != NAMES or plan['retirement']['requiresExplicitDeletionApproval'] is not True
            or plan['retirement']['fullDiskBackup'] is not False):
        raise ValueError('Named four-root retirement scope changed')
    roots = [runner.ROOT / name for name in NAMES]
    expected_removed = {str(path.relative_to(runner.ROOT)) for path in
                        (roots[0] / 'Disk.img', roots[2] / 'Disk.img')}
    if set(plan['retirement']['removedPreservedDiskIdentities']) != expected_removed:
        raise ValueError('Retirement disk-identity exceptions changed')
    if any(runner.VM == root or root in runner.VM.parents or runner.BACKUP == root
           or root in runner.BACKUP.parents for root in roots):
        raise ValueError('Selected continuation target or backup overlaps retirement')
    if any(name in plan['unrelatedDiskIdentities'] for name in expected_removed):
        raise ValueError('Retired disk still belongs to retained identity checks')


def approval(digest):
    runner.configure(digest)
    runner.base.approved(digest)
    value = json.loads(runner.base.evidence.read(runner.WORK / 'retirement-approval.json'))
    if value != dict(approved=True, planSHA256=digest, authorizedRetirementPaths=list(NAMES)):
        raise ValueError('Explicit four-root deletion approval required')


def verify_retired_disk_identities(plan):
    for name, expected in plan['retirement']['removedPreservedDiskIdentities'].items():
        info = (runner.ROOT / name).lstat()
        if dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size) != expected:
            raise ValueError('Named retired disk identity changed: ' + name)
    for row in plan['retirement']['retirementTargets']:
        if storage.metadata(runner.ROOT / row['path'] / 'Disk.img') != row['diskMetadata']:
            raise ValueError('Retirement disk metadata changed: ' + row['path'])


def failed_histories_only(plan):
    for name in NAMES:
        root = runner.ROOT / name
        if any(root.glob('.cfw_disk.*')) or (root / '.firmware-desired-pending.json').exists():
            raise ValueError('Pending publication in retirement candidate')
        records = list((root / '.cfw-history').glob('*/transaction.json'))
        if ((name in (NAMES[0], NAMES[2]) and not records)
                or any(json.loads(runner.base.evidence.read(p))['status'] != 'failed' for p in records)):
            raise ValueError('Retirement candidate contains non-failed history')
        row = next(row for row in plan['retirement']['retirementTargets'] if row['path'] == name)
        actual = {str(p.relative_to(root)): runner.snapshot(p) for p in records}
        if actual != row['failedTransactionRecords']:
            raise ValueError('Retirement failed history changed')


def execute(plan, digest):
    if os.geteuid() != 0:
        raise ValueError('Native administrator authentication required')
    configure(); runner.validate(plan); validate_scope(plan); approval(digest)
    runner.base.verify_inputs(plan); runner.base.verify_execution_inputs()
    if OUT.exists() or (runner.WORK / 'execution').exists() or runner.BACKUP.exists():
        raise ValueError('Existing retirement or continuation output; no replay')
    protected = dict(plan['frozenInputs'])
    protected.update(json.loads(runner.base.evidence.read(runner.WORK / 'executor-inputs.json'))['files'])
    for name in ('offline-plan.json', 'executor-inputs.json', 'approval.json', 'retirement-approval.json'):
        path = runner.WORK / name; protected[str(path)] = storage.sha(path)
    roots = storage.validate_roots(plan['retirement'], protected)
    if subprocess.check_output(['/usr/bin/git', '-c', 'safe.directory=' + str(runner.ROOT),
                               'ls-files', '-z', '--', *NAMES], cwd=runner.ROOT):
        raise ValueError('Tracked files in retirement roots')
    OUT.mkdir(mode=0o755)
    identity = subprocess.check_output(['/bin/ps', '-p', str(os.getpid()), '-o', 'uid=,lstart='],
        text=True, env=dict(os.environ, LC_ALL='C')).strip()
    runner.base.save(runner.WORK / 'native-root-identity.json', dict(pid=os.getpid(), uidAndStart=identity))
    result = dict(state='checking', removed=[], VMStarts=0, securityWindows=0, CFWWrites=0,
                  planSHA256=digest, fullDiskBackup=False)
    handles = []
    storage.save('result.json', result)
    try:
        for path in roots: storage.acquire(path, handles, directory=True)
        storage.attachments(roots); failed_histories_only(plan); verify_retired_disk_identities(plan)
        runner.previous.unrelated(plan)
        inventories = {str(path.relative_to(runner.ROOT)): storage.inventory(path) for path in roots}
        for items in inventories.values():
            for name, info in items.items():
                if stat.S_ISREG(info['mode']) and Path(name).name in (
                        'Disk.img', 'guest-postimage.img', '.vphone-online-operation.lock', '.firmware-desired.lock'):
                    storage.acquire(runner.ROOT / name, handles)
        for path in roots: storage.unused(path)
        storage.unchanged_inputs(protected)
        result['sourceBaselineBefore'] = runner.base.baseline(plan)
        with runner.base.audit.locked_vm(runner.VM):
            runner.existing_locked(plan['targets'][0])
        archived = storage.archive_small_records(inventories)
        raw = json.dumps(inventories).encode()
        inventory_file = OUT / 'inventory.json.gz'; inventory_file.write_bytes(gzip.compress(raw, mtime=0))
        inventory_file.chmod(0o600)
        if gzip.decompress(inventory_file.read_bytes()) != raw:
            raise ValueError('Retirement inventory archive readback differs')
        result.update(metadataFilesArchived=archived, inventoryEntries=sum(map(len, inventories.values())),
                      inventorySHA256=storage.sha(inventory_file), freeBytesBefore=shutil.disk_usage(runner.ROOT).free,
                      state='removing')
        storage.save('result.json', result)
        storage.remove_verified(roots, inventories, result['removed'])
        storage.unchanged_inputs(protected); runner.previous.unrelated(plan)
        result['sourceBaselineAfter'] = runner.base.baseline(plan)
        with runner.base.audit.locked_vm(runner.VM):
            runner.existing_locked(plan['targets'][0])
        result.update(state='completed', freeBytesAfter=shutil.disk_usage(runner.ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - result['freeBytesBefore']
        result['capacity75GiBPassed'] = result['freeBytesAfter'] >= plan['minimumInitialFreeBytes']
        storage.save('result.json', result)
    except Exception as error:
        result.update(state='failed', error=str(error)); storage.save('result.json', result)
        raise
    finally:
        for fd in reversed(handles): os.close(fd)
    return continue_if_capacity(plan, digest, result)


def continue_if_capacity(plan, digest, result):
    if not result['capacity75GiBPassed']:
        storage.save('pipeline-result.json', dict(state='awaiting-capacity', nativeStarted=False))
        return 0
    storage.save('pipeline-result.json', dict(state='native-running', nativeStarted=True))
    # A single already-authenticated process executes the approved continuation.
    status = runner.execute(plan, digest)
    storage.save('pipeline-result.json', dict(state='native-finished', nativeStarted=True, exitCode=status))
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply-approved', required=True)
    args = parser.parse_args()
    path = runner.WORK / 'offline-plan.json'
    digest = runner.base.evidence.digest(path)
    if args.apply_approved != digest:
        raise ValueError('Wrong named plan digest')
    return execute(json.loads(runner.base.evidence.read(path)), digest)


if __name__ == '__main__':
    raise SystemExit(main())

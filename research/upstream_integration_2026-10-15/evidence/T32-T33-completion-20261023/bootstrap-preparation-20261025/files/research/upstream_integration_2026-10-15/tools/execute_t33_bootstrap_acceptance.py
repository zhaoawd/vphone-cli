"""One separately approved bootstrap continuation; preserve the existing SSH marker."""
import argparse
import json
import os
from pathlib import Path
import subprocess

import execute_t33_dev_overlay_acceptance as runner

WORK = runner.BASE / 'exp-bootstrap-acceptance-20261025'
BACKUP = runner.BASE / 't33t-before-bootstrap-20261025'
VERSION = '2.6.2-local.3ffd9e46ee74'
ARCHIVE_SHA = 'fe682f4acd26974834ebd8a8776c63626022277df26ff0e4ef4008b6b7723991'
HOST_ARCHIVE_POLICY = 'original uid/gid are recorded separately from the user-owned archive carrier'


def configure():
    runner.WORK = WORK
    runner.BACKUP = BACKUP
    runner.VERSION = VERSION
    runner.ARCHIVE_SHA = ARCHIVE_SHA
    runner.CLI = Path('/Library/Application Support/vphone-launchpad/Bundles') / VERSION / 'VPhone.bundle/Contents/MacOS/vphone-cli'


def validate(plan):
    configure()
    runner.validate(plan)
    if ('retirement' in plan or plan.get('regularCFWRepeated') is not False
            or plan.get('priorFailedPlanSHA256') != '98a945b11297ed51b169f5a2ab1b0892d5bc49f5949c4b5304874b5ef9145f2e'
            or set(plan['targets'][0]['priorFailedTransactions']) !=
                {'20261025T021021Z-hnTJT23g', '20261025T043518Z-1urmPFY7', '20261025T100633Z-Bvlz2q7C'}):
        raise ValueError('Bootstrap continuation scope changed')
    protected = plan.get('protectedHostInputs', {})
    if set(protected) != {'.ssh_forward'}:
        raise ValueError('Existing SSH marker must be backed up')
    row = protected['.ssh_forward']
    if row.get('ownershipPolicy') != HOST_ARCHIVE_POLICY:
        raise ValueError('Explicit original ownership archive policy required')
    if row.get('backup') != str(WORK / 'host-input-backup/.ssh_forward'):
        raise ValueError('Host marker backup outside exact preparation path')
    keys = {'sha256','bytes','dev','ino','mtime_ns','mode','uid','gid'}
    if set(row.get('current', {})) != keys or set(row.get('backupState', {})) != keys:
        raise ValueError('Complete host marker identities required')
    if any(row['current'][k] != row['backupState'][k] for k in keys - {'dev','ino','uid','gid'}):
        raise ValueError('Host marker backup content or metadata differs')
    return plan


def verify_host_inputs(plan, *, current_inputs=True):
    for name, row in plan['protectedHostInputs'].items():
        if runner.snapshot(Path(row['backup'])) != row['backupState']:
            raise ValueError('Protected host marker backup changed')
        if current_inputs and runner.snapshot(runner.VM / name) != row['current']:
            raise ValueError('Host marker changed before execution')


def prepare_executor(plan, digest):
    runner.configure(digest)
    runner.base.verify_inputs(plan)
    inputs = runner.base.execution_inputs(plan)
    for name in ('execute_t33_target_binding_acceptance.py', 'execute_t33_dev_overlay_acceptance.py',
                 'execute_t33_bootstrap_acceptance.py', 'prepare_t33_bootstrap_acceptance.py',
                 'finalize_t33_bootstrap_acceptance.py', 'finalize_t33_target_binding_acceptance.py',
                 'finalize_t33_dev_overlay_acceptance.py', 'test_t33_bootstrap_acceptance.py'):
        path = Path(__file__).with_name(name).resolve(strict=True)
        inputs[str(path)] = runner.base.evidence.digest(path)
    launcher = Path(__file__).with_name('launch_t33_bootstrap_acceptance.py').resolve(strict=True)
    inputs[str(launcher)] = runner.base.evidence.digest(launcher)
    runner.base.save(WORK / 'executor-inputs.json', dict(planSHA256=digest, files=inputs))
    return dict(state='prepared-not-approved', planSHA256=digest, inputs=len(inputs))


def execute(plan, digest):
    runner.configure(digest)
    if os.geteuid() != 0:
        raise ValueError('Native administrator authentication required')
    runner.base.approved(digest)
    runner.base.verify_execution_inputs()
    # A failure before execution/result.json also consumes this invocation.
    (WORK / 'native-execution.claim').mkdir(mode=0o700)
    identity = subprocess.check_output(['/bin/ps', '-p', str(os.getpid()), '-o', 'uid=,lstart='],
        text=True, env=dict(os.environ, LC_ALL='C')).strip()
    runner.base.save(WORK / 'native-root-identity.json', dict(pid=os.getpid(), uidAndStart=identity))
    try:
        verify_host_inputs(plan)
        code = runner.execute(plan, digest)
        verify_host_inputs(plan, current_inputs=False)
        runner.base.save(WORK / 'host-input-backup-verification.json',
            dict(passed=True, files=1, planSHA256=digest, scope='complete preserved host marker bytes and original metadata record'))
        return code
    except Exception as error:
        runner.base.save(WORK / 'preflight-stopped.json', dict(state='failed', error=str(error),
            VMStarts=0, securityWindows=0, automaticRetry=False, planSHA256=digest))
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare-executor', action='store_true')
    group.add_argument('--execute-approved-plan')
    args = parser.parse_args()
    plan = validate(json.loads(runner.base.evidence.read(WORK / 'offline-plan.json')))
    digest = runner.base.evidence.digest(WORK / 'offline-plan.json')
    if args.prepare_executor:
        print(json.dumps(prepare_executor(plan, digest)))
        return 0
    if args.execute_approved_plan != digest:
        raise ValueError('Wrong bootstrap continuation digest')
    return execute(plan, digest)


if __name__ == '__main__':
    raise SystemExit(main())

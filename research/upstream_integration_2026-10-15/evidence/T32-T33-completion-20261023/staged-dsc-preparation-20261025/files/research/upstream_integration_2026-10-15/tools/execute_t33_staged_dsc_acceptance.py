"""One separately approved offline staged-DSC continuation; no retirement or boot."""
import argparse
import json
import os
from pathlib import Path
import subprocess

import execute_t33_dev_overlay_acceptance as runner

WORK = runner.BASE / 'exp-staged-dsc-acceptance-20261025'
BACKUP = runner.BASE / 't33t-before-staged-dsc-20261025'
VERSION = '2.6.2-local.9770cba52828'
ARCHIVE_SHA = '5b46529856c034480526a249ce2b59f17c0a9e4c674ec6710542e45f9b4252c8'


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
            or plan.get('priorFailedPlanSHA256') != '242f80d4a9b7dedd9e09fa59ad8918ad542436789bddca9b795ce3bb34714edd'
            or set(plan['targets'][0]['priorFailedTransactions']) !=
                {'20261025T021021Z-hnTJT23g', '20261025T043518Z-1urmPFY7'}):
        raise ValueError('Staged DSC continuation scope changed')
    return plan


def prepare_executor(plan, digest):
    runner.configure(digest)
    runner.base.verify_inputs(plan)
    inputs = runner.base.execution_inputs(plan)
    for name in ('execute_t33_target_binding_acceptance.py', 'execute_t33_dev_overlay_acceptance.py',
                 'execute_t33_staged_dsc_acceptance.py', 'prepare_t33_staged_dsc_acceptance.py',
                 'finalize_t33_staged_dsc_acceptance.py', 'finalize_t33_target_binding_acceptance.py',
                 'finalize_t33_dev_overlay_acceptance.py', 'test_t33_staged_dsc_acceptance.py'):
        path = Path(__file__).with_name(name).resolve(strict=True)
        inputs[str(path)] = runner.base.evidence.digest(path)
    launcher = Path(__file__).with_name('launch_t33_staged_dsc_acceptance.py').resolve(strict=True)
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
        return runner.execute(plan, digest)
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
        raise ValueError('Wrong staged DSC continuation digest')
    return execute(plan, digest)


if __name__ == '__main__':
    raise SystemExit(main())

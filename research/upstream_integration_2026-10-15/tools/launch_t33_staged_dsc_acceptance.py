"""Start the approved worker detached from the administrator authentication UI."""
import json
import os
import subprocess

import execute_t33_staged_dsc_acceptance as current


def start():
    if os.geteuid() != 0:
        raise ValueError('Administrator authentication required')
    runner = current.runner
    plan = current.validate(json.loads(runner.base.evidence.read(current.WORK / 'offline-plan.json')))
    digest = runner.base.evidence.digest(current.WORK / 'offline-plan.json')
    runner.configure(digest)
    runner.base.approved(digest)
    runner.base.verify_inputs(plan); runner.base.verify_execution_inputs()
    for name in ('native-execution.claim', 'native-root-identity.json', 'root-execution.log',
                 'execution', 'preflight-stopped.json'):
        if os.path.lexists(current.WORK / name):
            raise ValueError('Existing native attempt; no replay')
    (current.WORK / 'native-launch.claim').mkdir(mode=0o700)
    with (current.WORK / 'root-execution.log').open('xb') as output:
        os.chmod(current.WORK / 'root-execution.log', 0o644)
        process = subprocess.Popen([str(runner.ROOT / '.venv/bin/python'), '-B', '-u',
            str(runner.ROOT / 'research/upstream_integration_2026-10-15/tools/execute_t33_staged_dsc_acceptance.py'),
            '--execute-approved-plan', digest], cwd=runner.ROOT,
            stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
            close_fds=True, start_new_session=True,
            env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1'))
    runner.base.save(current.WORK / 'root-launch.json', dict(pid=process.pid, planSHA256=digest))
    print(json.dumps(dict(state='root-worker-started', pid=process.pid, planSHA256=digest)), flush=True)


if __name__ == '__main__':
    start()

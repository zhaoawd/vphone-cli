"""Launch exactly one approved recovery worker; never replace prior claims."""
import json
import os
from pathlib import Path
import subprocess

import execute_t33_source_acceptance as current


def start():
    if os.geteuid() != 0: raise ValueError('Administrator authentication required')
    base = current.base
    plan = current.validate(current.read(current.WORK / 'offline-plan.json'))
    digest = base.evidence.digest(current.WORK / 'offline-plan.json'); current.configure(digest)
    base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs()
    for name in ('native-launch.claim', 'native-execution.claim', 'native-root-identity.json', 'root-execution.log', 'execution'):
        if os.path.lexists(current.WORK / name): raise ValueError('Existing recovery launch or execution; no replay')
    (current.WORK / 'native-launch.claim').mkdir(mode=0o700)
    with (current.WORK / 'root-execution.log').open('xb') as output:
        os.chmod(current.WORK / 'root-execution.log', 0o644)
        process = subprocess.Popen([str(current.ROOT / '.venv/bin/python'), '-B', '-u',
            str(Path(__file__).with_name('execute_t33_source_acceptance.py')), '--execute-approved-plan', digest],
            cwd=current.ROOT, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
            close_fds=True, start_new_session=True,
            env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1'))
    base.save(current.WORK / 'root-launch.json', dict(pid=process.pid, planSHA256=digest))
    print(json.dumps(dict(state='root-worker-started', pid=process.pid, planSHA256=digest)), flush=True)


if __name__ == '__main__':
    start()

"""Start the approved root worker with all AppleScript pipes detached."""
import json
import os
from pathlib import Path
import subprocess

import retire_t32_t33_states_20261025 as cleanup

ROOT = cleanup.ROOT
OUT = cleanup.OUT


def start():
    if os.geteuid() != 0:
        raise ValueError('Administrator authentication required')
    inputs = json.loads((OUT / 'cleanup-inputs.json').read_bytes())
    cleanup.unchanged_inputs(inputs['files'])
    if any((OUT / name).exists() for name in
           ('native-launch.claim', 'root-launch.pid', 'root-execution.log', 'result.json')):
        raise ValueError('Existing launch/cleanup evidence; do not replay')
    (OUT / 'native-launch.claim').mkdir(mode=0o700)
    with (OUT / 'root-execution.log').open('xb') as output:
        process = subprocess.Popen([
            str(ROOT / '.venv/bin/python'), '-u',
            str(ROOT / 'research/retire_t32_t33_states_20261025.py'),
            '--apply-approved', cleanup.NEW],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
            close_fds=True, start_new_session=True,
            env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', PYTHONNOUSERSITE='1'))
    with (OUT / 'root-launch.pid').open('x') as stream:
        stream.write(str(process.pid) + '\n')
    (OUT / 'root-launch.pid').chmod(0o644)
    print(json.dumps(dict(state='root-worker-started', pid=process.pid, planSHA256=cleanup.NEW)), flush=True)
    return process.pid


if __name__ == '__main__':
    start()

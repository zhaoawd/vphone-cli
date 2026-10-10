#!/usr/bin/env python3
"""本轮离线回归监管；0.5 秒检查余量，低于 5 GiB 停止本轮子进程组。"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from t08_workspace import FLOOR, load_workspace
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace', type=Path, default=Path(__file__).with_name('workspace.json'))
args = parser.parse_args()
paths = load_workspace(args.workspace)
paths.work_root.mkdir(parents=True, exist_ok=True)
cache = paths.work_root / 'module-cache'
temp = paths.work_root / 'tmp'
temp.mkdir(exist_ok=True)
env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(temp),
           CLANG_MODULE_CACHE_PATH=str(cache), SWIFTPM_MODULECACHE_OVERRIDE=str(cache),
           VPHONE_DAEMON_SOURCE_PACKAGES=str(paths.packages))
commands = [([sys.executable, '-B', str(paths.evidence / 'regression_suite.py')], 'regressions'),
            (['make', '-C', 'sources/VPhoneGuestComponents', 'test-loader-links', 'test-vcam-dataplane'], 'component-host-tests')]
records = []
minimum = paths.check_space()
for command, label in commands:
    started = time.monotonic()
    reason = 'completed'
    minimum = min(minimum, paths.check_space())
    with (paths.evidence / (label + '.txt')).open('wb') as log:
        process = subprocess.Popen(command, cwd=paths.code_root, env=env,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        while process.poll() is None:
            state = os.statvfs(paths.code_root)
            minimum = min(minimum, state.f_bavail * state.f_frsize)
            if minimum < FLOOR or time.monotonic() - started > 300:
                reason = 'disk_below_5_GiB' if minimum < FLOOR else 'five_minute_limit'
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                break
            time.sleep(.5)
    records.append({'command': command, 'label': label, 'exit': process.returncode,
                    'reason': reason, 'seconds': time.monotonic() - started})
    (paths.evidence / 'regression-commands.json').write_text(json.dumps(
        {'commands': records, 'minimum_free_bytes': minimum, 'runtime_executed': False}, indent=2) + '\n')
    print(label, process.returncode, reason, flush=True)
    if process.returncode or reason != 'completed':
        sys.exit(1)

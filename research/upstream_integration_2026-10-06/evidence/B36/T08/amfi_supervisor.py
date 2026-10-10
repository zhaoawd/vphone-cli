#!/usr/bin/env python3
"""监管本轮单 CDHash 驱动；只响应停止标记、磁盘阈值或两小时时限。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

repo = Path(__file__).resolve().parents[5]
run = repo / '.build/research-b36'
driver = repo / 'research/upstream_integration_2026-10-06/evidence/B35/T08/scoped_amfi.py'
assert os.geteuid() == 0
assert not (run / 'amfi-stop').exists(), 'stop marker already exists'
fs = os.statvfs(repo)
assert fs.f_bavail * fs.f_frsize >= 5 * 1024**3
started = time.monotonic()
reason = 'driver_exited'
minimum = fs.f_bavail * fs.f_frsize
with (run / 'amfi.log').open('wb') as log:
    process = subprocess.Popen(['/usr/bin/python3', '-u', str(driver), '--run'],
                               stdout=log, stderr=subprocess.STDOUT)
    (run / 'amfi-process.json').write_text(json.dumps(dict(supervisor_pid=os.getpid(),
        driver_pid=process.pid,started=time.time(),driver=str(driver)))+'\n')
    while process.poll() is None:
        state = os.statvfs(repo)
        minimum = min(minimum, state.f_bavail * state.f_frsize)
        if (run / 'amfi-stop').exists():
            reason = 'requested_stop'
        elif minimum < 5 * 1024**3:
            reason = 'disk_below_5_GiB'
        elif time.monotonic() - started > 7200:
            reason = 'two_hour_limit'
        else:
            time.sleep(0.5)
            continue
        process.send_signal(signal.SIGINT)
        break
    # 不强制终止系统 amfid/debugserver；detach 错误由外层独立核对。
    process.wait()
record = dict(exit=process.returncode,reason=reason,minimum_free_bytes=minimum,
              seconds=time.monotonic()-started)
(run / 'amfi-exit.json').write_text(json.dumps(record,indent=2)+'\n')

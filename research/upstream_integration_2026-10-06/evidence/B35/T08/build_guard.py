#!/usr/bin/env python3
"""在隔离源码中构建候选；磁盘低于 5 GiB 时停止本次构建进程组。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

repo = Path(__file__).resolve().parents[5]
snapshot = repo / '.build/research-b35/source'
label, target = sys.argv[1:]
floor = 5 * 1024**3

def available():
    state = os.statvfs(snapshot)
    return state.f_bavail * state.f_frsize

minimum = available()
assert minimum >= floor, 'STOP: disk below 5 GiB'
started = time.monotonic()
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(snapshot / '.build/modulecache'),
           SWIFTPM_MODULECACHE_OVERRIDE=str(snapshot / '.build/modulecache'))
if target == 'build':
    # 嵌套 sandbox-exec 在当前执行环境被拒绝；SwiftPM 配置和缓存限于快照。
    wrappers = snapshot / '.build/build-tools'
    wrappers.mkdir(parents=True, exist_ok=True)
    swift = wrappers / 'swift'
    swift.write_text('''#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" != build ]]; then exec /usr/bin/swift "$@"; fi
exec /usr/bin/swift "$@" --disable-sandbox \\
  --cache-path "${0:A:h:h}/swiftpm-cache" \\
  --config-path "${0:A:h:h}/swiftpm-config" \\
  --security-path "${0:A:h:h}/swiftpm-security"
''')
    swift.chmod(0o755)
    env['PATH'] = str(wrappers) + os.pathsep + env['PATH']
reason = 'completed'
with (repo / f'.build/research-b35/{label}.log').open('wb') as log:
    process = subprocess.Popen(['make', '-C', str(snapshot), target], stdout=log,
                               stderr=subprocess.STDOUT, env=env, start_new_session=True)
    while process.poll() is None:
        minimum = min(minimum, available())
        if minimum < floor:
            reason = 'disk_below_5_GiB'
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            break
        time.sleep(0.5)
record = dict(target=target, exit=process.returncode, reason=reason,
              minimum_free_bytes=minimum, final_free_bytes=available(),
              seconds=time.monotonic() - started, snapshot=str(snapshot))
(Path(__file__).parent / f'{label}-result.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record))
sys.exit(process.returncode if reason == 'completed' else 75)

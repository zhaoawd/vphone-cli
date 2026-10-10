#!/usr/bin/env python3
"""恢复已获授权的 vm-new 原启动命令及同一健康监测进程。"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
maintenance = json.loads((HERE / 'source-maintenance.json').read_text())
pid = maintenance['health']['pid']
record = {'started_at': time.time(), 'health_pid': pid}


def ps(field):
    return subprocess.check_output(['ps', '-p', str(pid), '-o', field + '='], text=True).strip()


def identity():
    assert ps('command') == maintenance['health_command']
    assert ps('lstart') == maintenance['health_started']
    current = json.loads(Path('/private/tmp/autophone-rigs/vm-new/health.pid').read_text())
    assert current['pid'] == pid


def disk_off(path):
    r = subprocess.run(['/usr/sbin/lsof', '-t', str(path)], capture_output=True, text=True)
    assert r.returncode == 1 and not r.stdout and not r.stderr, str(path)


def probe(state):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(5)
        sock.connect(str(REPO / 'vm-new/vphone.sock'))
        sock.sendall(json.dumps({'t': 'app_list', 'filter': 'running', 'screen': False,
                                'target': {'vm': 'vm-new', 'pid': state['pid'], 'instance_id': state['instanceID']}}).encode() + b'\n')
        raw = b''
        while b'\n' not in raw:
            part = sock.recv(65536)
            assert part
            raw += part
            assert len(raw) < 20 * 1024**2
        reply = json.loads(raw.split(b'\n')[0])
        return bool(reply.get('ok') and 'apps' in reply)


identity()
assert 'T' in ps('stat')
disk_off(REPO / 'vm-roothide-b33-20261010/Disk.img')
disk_off(REPO / 'vm-new/Disk.img')
assert os.statvfs(REPO).f_bavail * os.statvfs(REPO).f_frsize >= 5 * 1024**3
log_path = REPO / '.build/research-b36/source-restoration.private.log'
try:
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'wb') as log:
        source = subprocess.Popen(maintenance['source_argv'], cwd=REPO, stdin=subprocess.DEVNULL,
                                  stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    record['source_pid'] = source.pid
    print('SOURCE', source.pid, flush=True)
    deadline = time.monotonic() + 150
    successful = 0
    while time.monotonic() < deadline:
        assert source.poll() is None, 'source process exited'
        try:
            state = json.loads((REPO / 'vm-new/.vphone-runtime.json').read_text())
            assert state['pid'] == source.pid
            good = probe(state)
        except (OSError, ValueError, AssertionError):
            good = False
        successful = successful + 1 if good else 0
        if successful >= 3:
            record['runtime'] = state
            record['guest_roundtrip_verified'] = True
            break
        time.sleep(2)
    assert record.get('guest_roundtrip_verified'), 'source guest roundtrip did not become ready'
except Exception as exc:
    record['failure'] = {'type': type(exc).__name__, 'message': str(exc)}
if record.get('guest_roundtrip_verified'):
    identity()
    disk_off(REPO / 'vm-roothide-b33-20261010/Disk.img')
    os.kill(pid, signal.SIGCONT)
    record['health_resumed_at'] = time.time()
    record['health_state_after_signal'] = ps('stat')
    print('HEALTH SIGCONT', pid, record['health_state_after_signal'], flush=True)
    (HERE / 'source-restoration.json').write_text(json.dumps(record, indent=2) + '\n')

if not record.get('guest_roundtrip_verified'):
    (HERE / 'source-restoration.json').write_text(json.dumps(record, indent=2) + '\n')
    raise SystemExit(2)

for _ in range(20):
    state = json.loads(Path(maintenance['health']['state_file']).read_text())
    if state['ts'] > record['health_resumed_at'] and state['state'] == 'healthy' and state['probe_count'] >= 3747:
        record['health_snapshot'] = state
        break
    time.sleep(2)
record['final_free_bytes'] = os.statvfs(REPO).f_bavail * os.statvfs(REPO).f_frsize
(HERE / 'source-restoration.json').write_text(json.dumps(record, indent=2) + '\n')
print('RESTORED', bool(record.get('guest_roundtrip_verified')), bool(record.get('health_snapshot')), flush=True)
if record.get('failure') or not record.get('health_snapshot'):
    raise SystemExit(2)

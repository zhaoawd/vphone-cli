"""研究副本的串口、classic socket 和 API；调用前检查身份及余量。"""
import http.client
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time

repo = Path(__file__).resolve().parents[5]
vm = repo / 'vm-roothide-b33-20261010'
run = Path((repo / '.build/research-b33/current-run').read_text())
evidence = Path(__file__).resolve().parent

def check():
    assert not (run / 'exit.json').exists(), 'VM stopped'
    s = os.statvfs(vm)
    assert s.f_bavail * s.f_frsize >= 5 * 1024**3, 'STOP: disk below 5 GiB'
    state = json.loads((vm / '.vphone-runtime.json').read_text())
    assert state['pid'] == json.loads((run / 'process.json').read_text())['vm_pid']
    source = subprocess.run(['/usr/sbin/lsof', '-t', str(repo / 'vm-new/Disk.img')], capture_output=True, text=True)
    assert source.returncode == 1 and not source.stdout and not source.stderr, 'PAUSE: source VM active or check failed'
    return state

def serial(command):
    check()
    assert len(command.encode()) < 4000
    fd = os.open(run / 'serial-input', os.O_WRONLY)
    try:
        raw = (command + '\n').encode()
        assert os.write(fd, raw) == len(raw)
    finally:
        os.close(fd)

def ctl(t, **kw):
    state = check()
    q = dict(t=t, screen=False, target={'vm': vm.name, 'pid': state['pid'], 'instance_id': state['instanceID']}, **kw)
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(60)
        s.connect(str(vm / 'vphone.sock'))
        s.sendall(json.dumps(q).encode() + b'\n')
        raw = b''
        while b'\n' not in raw:
            part = s.recv(65536)
            assert part, 'socket closed'
            raw += part
            assert len(raw) < 20 * 1024**2
    return json.loads(raw.split(b'\n')[0])

def rpc(method=None, params=None):
    check()
    port = int(re.search(r'\[api\] proxy listening on http://127.0.0.1:(\d+)', (run / 'console-redacted.log').read_text(errors='replace'))[1])
    token = (run / 'token').read_text()
    c = http.client.HTTPConnection('127.0.0.1', port, timeout=60)
    start = time.monotonic()
    try:
        headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}
        if method:
            c.request('POST', '/v1/rpc', json.dumps({'method': method, 'params': params or {}, 'id': 'B33'}), headers)
        else:
            c.request('GET', '/v1/health', headers=headers)
        response = c.getresponse()
        result = {'method': method, 'params': params or {}, 'http_status': response.status, 'reply': json.loads(response.read()), 'seconds': time.monotonic() - start}
        assert token not in json.dumps(result)
        return result
    finally:
        c.close()

def save(name, value):
    raw = json.dumps(value, indent=2, ensure_ascii=False) + '\n'
    assert (run / 'token').read_text() not in raw
    (evidence / name).write_text(raw)

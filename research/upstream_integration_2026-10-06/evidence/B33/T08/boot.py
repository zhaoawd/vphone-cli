#!/usr/bin/env python3
"""启动本轮研究副本并持续监测磁盘；不安装或激活客户机组件。"""
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import threading
import time
import uuid

repo = Path(__file__).resolve().parents[5]
vm = repo / 'vm-roothide-b33-20261010'
root = repo / '.build/research-b33' / ('runtime-' + uuid.uuid4().hex[:8])
binary = repo / '.build/vphone-cli.app/Contents/MacOS/vphone-vm'
floor = 5 * 1024**3

def free():
    s = os.statvfs(vm)
    return s.f_bavail * s.f_frsize

assert free() >= floor
assert hashlib.sha256(binary.read_bytes()).hexdigest() == '35d53dbd71371180d599f684a1584fdf27fe1b48fb480a5d5bd6390419163623'
for disk in [vm / 'Disk.img', repo / 'vm-new/Disk.img']:
    c = subprocess.run(['/usr/sbin/lsof', '-t', str(disk)], capture_output=True, text=True)
    assert c.returncode == 1 and not c.stdout and not c.stderr, str(disk)
root.mkdir(parents=True, exist_ok=False)
os.chmod(root, 0o700)
(repo / '.build/research-b33/current-run').write_text(str(root))
token = secrets.token_urlsafe(32)
fd_token = os.open(root / 'token', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.write(fd_token, token.encode())
os.close(fd_token)
os.mkfifo(root / 'serial-input', 0o600)
fd = os.open(root / 'serial-input', os.O_RDWR)
stop = threading.Event()
watch_stop = threading.Event()
minimum = free()
reason = 'requested'
shutdown_lock = threading.Lock()
shutdown_sent = False
p = None

def shutdown():
    global shutdown_sent
    with shutdown_lock:
        if p is not None and p.poll() is None and not shutdown_sent:
            shutdown_sent = True
            p.send_signal(signal.SIGINT)

def watch():
    global minimum, reason
    while not watch_stop.is_set():
        minimum = min(minimum, free())
        if minimum < floor:
            reason = 'disk_below_5_GiB'
            stop.set()
            shutdown()
            return
        source = subprocess.run(['/usr/sbin/lsof', '-t', str(repo / 'vm-new/Disk.img')], capture_output=True, text=True)
        if source.returncode != 1 or source.stdout or source.stderr:
            reason = 'source_active_or_check_failed_pause_experiment'
            stop.set()
            shutdown()
            return
        watch_stop.wait(0.5)

def drain():
    with (root / 'console-redacted.log').open('wb') as log:
        for line in iter(p.stdout.readline, b''):
            if b'[location] got location:' in line:
                line = b'[location] got location: [coordinates omitted]\n'
            line = line.replace(token.encode(), b'[token omitted]')
            log.write(line)
            log.flush()

signal.signal(signal.SIGINT, lambda *_: stop.set())
signal.signal(signal.SIGTERM, lambda *_: stop.set())
started = time.monotonic()
# 当前已有宿主工件没有 --no-vphoned-update；将该副本原 classic
# 文件显式作为自动更新输入。该运行不用于默认产物来源一致性验收。
args = [str(binary), '--config', str(vm / 'config.plist'), '--variant', 'exp', '--headless', '--vphoned-bin', str(vm / '.vphoned.signed'), '--api-listen', '127.0.0.1:0']
try:
    p = subprocess.Popen(args, stdin=fd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=dict(os.environ, VPHONE_API_TOKEN=token, NSUnbufferedIO='YES'))
    (root / 'process.json').write_text(json.dumps({'monitor_pid': os.getpid(), 'vm_pid': p.pid, 'arguments': args}, indent=2) + '\n')
    reader = threading.Thread(target=drain)
    watcher = threading.Thread(target=watch)
    reader.start()
    watcher.start()
    print('BOOT', vm.name, 'pid', p.pid, flush=True)
    while p.poll() is None and not stop.is_set() and not (root / 'release').exists():
        if time.monotonic() - started > 7200:
            reason = 'two_hour_limit'
            break
        stop.wait(0.5)
finally:
    shutdown()
    if p is not None:
        try:
            p.wait(timeout=45)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
            reason += ';forced_kill'
        reader.join(timeout=10)
    watch_stop.set()
    watcher.join(timeout=2)
    os.close(fd)
    (root / 'exit.json').write_text(json.dumps({'exit': p.returncode, 'reason': reason, 'minimum_free_bytes': minimum, 'final_free_bytes': free(), 'seconds': time.monotonic() - started}, indent=2) + '\n')
    print('EXIT', p.returncode, reason, flush=True)

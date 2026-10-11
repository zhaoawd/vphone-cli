"""核对精确 vm-new 对象，暂停其健康监测并正常停止一次；自动重启则拒绝研究启动。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

HERE = Path(__file__).resolve().parent
REPO = Path('/Users/kolar/github/vphone-cli')
HEALTH = Path('/private/tmp/autophone-rigs/vm-new/health.pid')
assert os.statvfs(REPO).f_bavail * os.statvfs(REPO).f_frsize >= 5 * 1024**3
health = json.loads(HEALTH.read_text()); pid = health['pid']
def ps(pid, field): return subprocess.check_output(['ps','-p',str(pid),'-o',field+'='],text=True).strip()
old = json.loads((HERE.parents[1] / 'B36/T08/source-maintenance.json').read_text())
assert ps(pid,'command') == old['health_command']
assert health['sock'] == str(REPO / 'vm-new/vphone.sock')
state = json.loads((REPO / 'vm-new/.vphone-runtime.json').read_text())
source = state['pid']
assert ps(source,'command') == ' '.join(old['source_argv'])
r = subprocess.run(['/usr/sbin/lsof','-t',str(REPO / 'vm-roothide-b33-20261010/Disk.img')],capture_output=True,text=True)
assert r.returncode==1 and not r.stdout and not r.stderr
record = {'at':time.time(), 'health':health, 'health_command':ps(pid,'command'), 'health_started':ps(pid,'lstart'), 'source_runtime':state, 'source_argv':old['source_argv'], 'source_started':ps(source,'lstart'), 'authorized':'existing exact vm-new maintenance scope; new PID revalidated against same command/socket'}
(HERE / 'source-maintenance.json').write_text(json.dumps(record,indent=2)+'\n')
os.kill(pid,signal.SIGSTOP)
for _ in range(20):
 if 'T' in ps(pid,'stat'): break
 time.sleep(.1)
assert 'T' in ps(pid,'stat') and json.loads(HEALTH.read_text())['pid']==pid
record['health_pause_verified'] = ps(pid,'stat')
os.kill(source,signal.SIGINT); record['source_sigint_at'] = time.time()
(HERE / 'source-maintenance.json').write_text(json.dumps(record,indent=2)+'\n')
for _ in range(120):
 r = subprocess.run(['ps','-p',str(source),'-o','stat='],capture_output=True,text=True)
 if r.returncode or 'Z' in r.stdout: break
 time.sleep(.5)
else: raise RuntimeError('source did not stop normally; no repeated signal')
for _ in range(20):
 r = subprocess.run(['/usr/sbin/lsof','-t',str(REPO / 'vm-new/Disk.img')],capture_output=True,text=True)
 assert r.returncode==1 and not r.stdout and not r.stderr, 'PAUSE: source auto restart or disk holder'
 time.sleep(.5)
record['source_stopped_and_disk_released'] = True
(HERE / 'source-maintenance.json').write_text(json.dumps(record,indent=2)+'\n')
print('source stopped once; exact vm-new monitor paused',pid)

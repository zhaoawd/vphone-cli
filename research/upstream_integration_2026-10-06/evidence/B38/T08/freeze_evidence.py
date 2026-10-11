"""保存已完成运行的公开证据；不复制 token、私有恢复日志或磁盘映像。"""
import gzip
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
CODE = HERE.parents[4]
REPO = Path('/Users/kolar/github/vphone-cli')
BUILD = CODE / '.build/research-b38'
VM = REPO / 'vm-roothide-b33-20261010'

def save(name, data):
    (HERE / name).write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')

def capture(args):
    r = subprocess.run(args, capture_output=True, text=True)
    return {'command': args, 'exit': r.returncode, 'stdout': r.stdout, 'stderr': r.stderr}

restoration = json.loads((HERE / 'source-restoration.json').read_text())
maintenance = json.loads((HERE / 'source-maintenance.json').read_text())
assert restoration['guest_roundtrip_verified'] and restoration['health_snapshot']['state'] == 'healthy'
monitor = capture(['ps', '-p', str(maintenance['health']['pid']), '-o', 'stat=,lstart=,command='])
assert monitor['exit'] == 0 and 'T' not in monitor['stdout'].split()[0]
assert maintenance['health_command'] in monitor['stdout'] and maintenance['health_started'] in monitor['stdout']
source = capture(['ps', '-p', str(restoration['source_pid']), '-o', 'command='])
assert source['stdout'].strip() == ' '.join(maintenance['source_argv'])
held = capture(['/usr/sbin/lsof', '-t', str(VM / 'Disk.img')])
assert held['exit'] == 1 and not held['stdout'] and not held['stderr']
images = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist']))['images']
assert not any(str(VM) in img.get('image-path', '') for img in images)
health = json.loads(Path(maintenance['health']['state_file']).read_text())
assert health['state'] == 'healthy' and health['ts'] > restoration['health_resumed_at']
free = os.statvfs(REPO); free_bytes = free.f_bavail * free.f_frsize
assert free_bytes >= 5 * 1024**3
save('final-readback.json', {'at': time.time(), 'source': source, 'monitor': monitor,
     'source_health': health, 'research_disk_handles': held, 'research_images_attached': False,
     'free_bytes': free_bytes, 'new_amfi_attachment': False,
     'other_amfi_session': capture(['ps', '-p', '38515,38530', '-o', 'pid=,ppid=,lstart=,command='])})

for name, directory in [('first', 'runtime-fc862596'), ('second', 'runtime-6f22fbb5')]:
    run = BUILD / directory
    token = (run / 'token').read_bytes()
    raw = (run / 'console-redacted.log').read_bytes()
    assert token not in raw
    (HERE / (name + '-console.txt.gz')).write_bytes(gzip.compress(raw, mtime=0))
    for member in ['exit', 'process']:
        value = json.loads((run / (member + '.json')).read_text())
        assert token not in json.dumps(value).encode()
        save(name + '-' + member + '.json', value)
    assert json.loads((run / 'exit.json').read_text())['exit'] == 0

(HERE / 'guest-build.txt.gz').write_bytes(gzip.compress((BUILD / 'guest-build.log').read_bytes(), mtime=0))
shutil.copy2(BUILD / 'default-pack.log', HERE / 'default-pack.txt')
for src, dst in [('api/manifest.json', 'api-candidate-manifest.json'), ('cohort.json', 'default-cohort.json')]:
    shutil.copy2(CODE / '.build/guest' / src, HERE / dst)
trial = HERE / 'vphoned-api'
if trial.exists():
    json.loads(trial.read_text())
    trial.rename(HERE / 'second-cold-output-name-trial.json')

paths = ['scripts/vphoned', 'sources/VPhoneCore/VPhoneResources.swift',
         'sources/vphone-cli/VPhoneCLI.swift', 'sources/vphone-cli/VPhoneControl.swift',
         'sources/vphone-cli/VPhoneVMLaunchCLI.swift', 'sources/vphone-cli/VPhoneAppDelegate.swift']
diff = capture(['git', '-C', str(CODE), 'diff', 'a422e152e5d5def65b19f4ad37bad868eaebe328', '--', *paths])
assert diff['exit'] == 0 and not diff['stdout']
save('classic-compatibility.json', {'unchanged_since_B35': paths, 'source_diff': diff,
     'host_auto_update_resource': 'guest-resources/vphoned (classic)',
     'modern_api_resource': 'guest-resources/api/vphoned',
     'classic_cache': '/var/root/Library/Caches/vphoned',
     'modern_cache': '/var/root/Library/Caches/vphoned-api',
     'runtime_auto_update_policy': '--no-vphoned-update',
     'unflagged_old_guest_auto_update_retested': False,
     'limits': '源码核对及实际独立 API 更新保持 classic；没有重新执行无禁更标志的旧 guest 全部升级流程。'})
print('Runtime exits, restoration, source compatibility and redacted logs frozen')

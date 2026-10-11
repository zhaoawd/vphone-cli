"""复用已批准的宿主闭包，打包本轮默认 guest；不修改冻结 B35 app。"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from t08_workspace import load_workspace, digest
p = load_workspace(Path(__file__).with_name('workspace.json'))
source = p.bundle
target = p.work_root / 'default/vphone-cli.app'
assert not target.exists()
p.check_space()
# 宿主源码未改动；新增默认载荷不需要改动已批准的 VM 可执行文件。
old = json.loads((p.evidence.parents[1] / 'B35/T08/source-snapshot.json').read_text())
host = [e for e in old['sources'] if e['path'].startswith(('sources/vphone-cli/', 'sources/VPhoneCore/')) and not e['path'].endswith('VPhoneBuildInfo.swift')]
assert host
for item in host:
    assert digest(p.code_root / item['path']) == item['sha256'], item['path']
target.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['/bin/cp', '-cR', str(source), str(target)], check=True)
resources = target / 'Contents/Resources'
subprocess.run(['/usr/bin/rsync', '-a', '--exclude=__pycache__', '--exclude=.git', '--exclude=.build', str(p.code_root / 'scripts') + '/', str(resources / 'scripts') + '/'], check=True)
subprocess.run(['/usr/bin/rsync', '-a', str(p.code_root / '.build/guest') + '/', str(resources / 'guest-resources') + '/'], check=True)
assert digest(target / 'Contents/MacOS/vphone-vm') == 'a4f8a4155a95e3d0c9067f856bb09a165df22cc9e55fcf9356f01ab16b0d11f4'
subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True)
subprocess.run([sys.executable, '-B', str(p.code_root / 'scripts/check_bundle.py'), str(target)], check=True)
assert digest(target / 'Contents/MacOS/vphone-vm') == digest(source / 'Contents/MacOS/vphone-vm')
files = [*p.code_root.glob('sources/VPhoneDaemon/**/*'), *p.code_root.glob('dependencies/**/*'), p.code_root / 'scripts/build_daemon_api.sh', p.code_root / 'scripts/check_guest_api.py']
inputs = [{'path': str(f.relative_to(p.code_root)), 'sha256': digest(f)} for f in sorted(files) if f.is_file() and not f.is_symlink() and '__pycache__' not in f.parts]
record = {'bundle': str(target), 'host_build': 'unchanged signed B35 host closure reused', 'host_inputs_verified': len(host), 'guest_built_from_current_worktree': True, 'api_sha256': digest(resources / 'guest-resources/api/vphoned'), 'vm_sha256': digest(target / 'Contents/MacOS/vphone-vm'), 'vm_cdhash': '62026af109b33fdd468c2c2df2fcdb4211136bf0', 'inputs': inputs, 'cohort': json.loads((resources / 'guest-resources/cohort.json').read_text()), 'runtime_validated': False, 'free_bytes': p.check_space()}
(p.evidence / 'default-artifact.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({k:v for k,v in record.items() if k not in ('inputs', 'cohort')}))

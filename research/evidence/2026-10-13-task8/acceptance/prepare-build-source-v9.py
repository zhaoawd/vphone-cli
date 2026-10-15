import datetime
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess

ROOT = Path('/Users/qcz3840/github/vphone-cli')
BUILD = Path('/private/tmp/vphone-task8-acceptance-build')
E = ROOT / 'research/evidence/2026-10-13-task8/acceptance'
DIRS = ['sources', 'scripts', 'vendor', 'dependencies', 'tools', 'tests']
FILES = ['Package.swift', 'Package.resolved', 'Makefile', 'requirements.txt', 'debs.list', 'README.md', '.gitmodules']
EXCLUDED = {'.git', '.build', '__pycache__', '.DS_Store'}

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def source_files(base):
    found = [base / name for name in FILES]
    for name in DIRS:
        found += [p for p in (base / name).rglob('*') if p.is_file() and not EXCLUDED.intersection(p.relative_to(base).parts) and p.suffix != '.pyc']
    return {str(p.relative_to(base)): sha(p) for p in sorted(found)}

rollback = json.loads((E / 'kernel-rollback/manifest.json').read_text())
for entry in rollback['sourceFiles']:
    frozen = ROOT / entry['path']
    assert sha(frozen) == entry['sha256'] and frozen.stat().st_size == entry['size'], entry['path']
assert not (E / 'build-source-v9-manifest.json').exists()
assert not (BUILD / 'core-candidate-v9').exists()
preserved = {}
for p in sorted(E.iterdir()):
    if p.is_file() and 'v9' not in p.name and any(p.name.startswith(prefix) for prefix in ['build-source', 'core-candidate', 'signed-app', 'signed-build', 'package-core-candidate', 'prepare-build-source', 'freeze-core-candidate', 'v1-', 'v2-', 'v3-', 'v4-', 'v5-', 'v6-', 'v7-', 'v8-']):
        preserved[p.name] = sha(p)
(E / 'v1-v8-evidence-preservation-before-v9.json').write_text(json.dumps(preserved, indent=2) + '\n')
assert not (BUILD / 'signed-app-v8.app').exists()
subprocess.run(['/bin/cp', '-cR', str(BUILD / '.build/vphone-cli.app'), str(BUILD / 'signed-app-v8.app')], check=True)
app = BUILD / 'signed-app-v8.app'
app_files = {str(p.relative_to(app)): sha(p) for p in sorted(app.rglob('*')) if p.is_file()}
assert app_files == {str(p.relative_to(BUILD / '.build/vphone-cli.app')): sha(p) for p in sorted((BUILD / '.build/vphone-cli.app').rglob('*')) if p.is_file()}
(E / 'signed-app-v8-preservation-before-v9.json').write_text(json.dumps({'path': str(app), 'files_sha256': app_files}, indent=2) + '\n')
production = source_files(ROOT)
for name in DIRS:
    subprocess.run(['/usr/bin/rsync', '-a', '--delete', '--exclude', '.git', '--exclude', '.build', '--exclude', '__pycache__', '--exclude', '.DS_Store', '--exclude', '*.pyc', str(ROOT / name) + '/', str(BUILD / name) + '/'], check=True)
for name in FILES:
    shutil.copy2(ROOT / name, BUILD / name)
info = BUILD / 'sources/Info.plist'
data = plistlib.loads(info.read_bytes())
data['CFBundleShortVersionString'] = '2.6.20261021'
data['CFBundleVersion'] = '2026101404'
info.write_bytes(plistlib.dumps(data, sort_keys=False))
manifest = json.loads((E / 'build-source-v8-manifest.json').read_text())
manifest.update(version='2.6.20261021-local', build_overrides={'CFBundleShortVersionString': '2.6.20261021', 'CFBundleVersion': '2026101404'}, files_sha256=source_files(BUILD))
manifest['production_files_sha256'] = production
manifest['kernel_rollback_freeze_manifest_sha256'] = sha(E / 'kernel-rollback/manifest.json')
manifest['kernel_rollback_frozen_source_files'] = rollback['sourceFiles']
manifest['recorded_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
manifest['source_commit'] = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
manifest['submodules'] = subprocess.check_output(['git', '-C', str(ROOT), 'submodule', 'status', '--recursive'], text=True)
manifest['capstone_worktree_diff'] = subprocess.check_output(['git', '-C', str(ROOT / 'vendor/libcapstone-spm'), 'diff'], text=True)
prior = json.loads((E / 'build-source-v8-manifest.json').read_text())['production_files_sha256']
manifest['changed_files_from_v8'] = sorted(p for p in set(production) | set(prior) if production.get(p) != prior.get(p))
assert set(manifest['changed_files_from_v8']) == {entry['path'] for entry in rollback['sourceFiles']}, manifest['changed_files_from_v8']
(E / 'build-source-v9-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
overrides = ['sources/Info.plist', 'sources/vphone-cli/VPhoneBuildInfo.swift']
mismatches = [p for p, h in production.items() if p not in overrides and manifest['files_sha256'].get(p) != h]
extra = sorted(set(manifest['files_sha256']) - set(production))
comparison = {'production_mismatches': mismatches, 'new_production_files_not_in_manifest': sorted(set(production) - set(manifest['files_sha256'])), 'build_files_not_in_production': extra, 'intentional_overrides': overrides, 'source_manifest_sha256': sha(E / 'build-source-v9-manifest.json')}
(E / 'build-source-v9-current-comparison.json').write_text(json.dumps(comparison, indent=2) + '\n')
assert not mismatches and not comparison['new_production_files_not_in_manifest'] and not extra
script = (E / 'package-core-candidate-v8.py').read_text().replace('v8', 'v9').replace('2.6.20261020-local', '2.6.20261021-local')
(E / 'package-core-candidate-v9.py').write_text(script)
print(json.dumps({'source_file_count': len(manifest['files_sha256']), 'comparison': comparison, 'changed_files_from_v8': manifest['changed_files_from_v8']}, indent=2))

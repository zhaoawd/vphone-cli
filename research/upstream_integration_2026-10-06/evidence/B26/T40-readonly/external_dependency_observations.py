"""Read-only dependency observations, not a toolchain freeze or VM acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', required=True, type=Path)
p.add_argument('--python', required=True, type=Path)
p.add_argument('--output', required=True, type=Path)
a = p.parse_args()
assert str(a.output.absolute()).startswith('/private/tmp/vphone-b26-t40/')
a.output.mkdir(mode=0o700, parents=False, exist_ok=False)
report = {'scope': 'read-only observations only; external dependencies remain mutable', 'commands': [], 'files': {}, 'tools': {}}
env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
def observe(label, argv):
    r = subprocess.run(argv, env=env, capture_output=True, timeout=120)
    (a.output/(label+'.stdout')).write_bytes(r.stdout)
    (a.output/(label+'.stderr')).write_bytes(r.stderr)
    report['commands'].append({'label': label, 'argv': argv, 'returncode': r.returncode,
                                'stdout': label+'.stdout', 'stderr': label+'.stderr'})
    return r
def identity(path):
    f = Path(path)
    if not f.is_file():
        return {'path': str(f), 'exists': False}
    s = f.stat()
    return {'path': str(f), 'resolved_path': str(f.resolve()), 'bytes': s.st_size,
            'sha256': hashlib.file_digest(f.open('rb'), 'sha256').hexdigest()}
report['files']['selected_project_python'] = identity(a.python)
observe('python-info', [str(a.python), '-B', '-c', 'import json,sys,sysconfig;print(json.dumps(dict(executable=sys.executable,prefix=sys.prefix,base_prefix=sys.base_prefix,paths=sysconfig.get_paths(),sys_path=sys.path),indent=2))'])
observe('python-native-links', ['/usr/bin/otool', '-L', str(a.python.resolve())])
observe('development-locked-probe', [str(a.python), '-B', str(a.source/'scripts/check_python_runtime.py'), '--locked', '--json'])
observe('installed-locked-probe', [str(a.python), '-B', str(a.source/'.build/vphone-cli.app/Contents/Resources/scripts/check_python_runtime.py'), '--locked', '--json'])
for name in ['bash', 'zsh', 'python3', 'tar', 'gtar', 'zstd', 'ipsw', 'aea', 'ldid', 'insert_dylib', 'trustcache', 'xcrun', 'clang', 'curl', 'aria2c', 'wget', 'hdiutil', 'diskutil', 'shasum', 'cp', 'find']:
    selected = shutil.which(name)
    report['tools'][name] = identity(selected) if selected else {'exists': False}
for name in ['AVPBooter.vresearch1.bin', 'AVPSEPBooter.vresearch1.bin']:
    report['files'][name] = identity(Path('/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources')/name)
sdk = observe('iphoneos-sdk-path', ['/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-path'])
clang = observe('iphoneos-clang-path', ['/usr/bin/xcrun', '--sdk', 'iphoneos', '-f', 'clang'])
if sdk.returncode == 0:
    report['files']['SDKSettings.plist'] = identity(Path(sdk.stdout.decode().strip())/'SDKSettings.plist')
if clang.returncode == 0:
    report['files']['iphoneos-clang'] = identity(clang.stdout.decode().strip())
report['limitations'] = ['Executable and SDKSettings hashes do not cover frameworks, stdlib, package payloads, SDK contents or compiler resources',
                          'Host PATH observation is not the rebuilt CFW PATH or immutable dependency selection',
                          'No packages, tools, SDK, ROM, existing VM inputs or caches were copied or frozen',
                          'Locked package versions and capability probe do not verify installed package bytes']
(a.output/'result.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({'commands': len(report['commands']), 'files': len(report['files']), 'tools': len(report['tools']), 'result': str(a.output/'result.json')}))

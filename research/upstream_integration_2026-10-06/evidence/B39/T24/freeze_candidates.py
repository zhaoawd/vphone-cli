"""Freeze B39 host candidates in this worktree; never install a system Bundle."""
import hashlib, importlib.util, json, os, plistlib, subprocess, tarfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
WORK = ROOT / '.build/research-b39'

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()

def run(*args):
    p = subprocess.run([str(x) for x in args], capture_output=True, text=True)
    if p.returncode: raise RuntimeError(p.stderr or p.stdout)
    return p.stdout, p.stderr

def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

native = load_module('native', ROOT / 'scripts/build_native_dependencies.py')
inputs = {p: sha(ROOT / p) for p in (
    'Package.swift', 'Package.resolved', 'sources/Info.plist', 'sources/vphone.entitlements',
    'sources/VPhoneBundleStore/VPhoneBundleReceipt.swift',
    'sources/VPhoneBundleStore/VPhoneCoreBundleStore.swift',
    'sources/vphone-cli/VPhoneVMLaunchCLI.swift')}
head = run('git', '-C', ROOT, 'rev-parse', 'HEAD')[0].strip()
source = {'base_commit': head, 'inputs_sha256': inputs,
          'production_diff_sha256': hashlib.sha256(run('git', '-C', ROOT, 'diff', '--', 'sources')[0].encode()).hexdigest()}
source_digest = hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest()
version = '2.6.1-local.' + source_digest[:12]
app = ROOT / '.build/vphone-cli.app'
launchpad = ROOT / '.build/vphone-launchpad.app'
stage = WORK / 'core-candidate'
stage.mkdir(exist_ok=False)
bundle = stage / 'VPhone.bundle'
run('/bin/cp', '-cR', app, bundle)
info_path = bundle / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
assert info['VPhoneBoundLaunchProtocol'] == 'vphone.local-bound-launch.v1'
changes = {'CFBundleShortVersionString': {'old': info['CFBundleShortVersionString'], 'new': '2.6.1'},
           'CFBundlePackageType': {'old': info['CFBundlePackageType'], 'new': 'BNDL'}}
for key, value in changes.items(): info[key] = value['new']
info_path.write_bytes(plistlib.dumps(info))
run('/usr/bin/codesign', '--force', '--sign', '-', '--identifier', info['CFBundleIdentifier'], bundle)
archive = WORK / (version + '.tar')
# A dedicated root avoids hard links and AppleDouble/xattr sidecar entries.
with tarfile.open(archive, 'x', format=tarfile.PAX_FORMAT, dereference=False) as out:
    out.add(bundle, arcname='VPhone.bundle', recursive=True)

def signature(path):
    run('/usr/bin/codesign', '--verify', '--strict', '--deep', path)
    _, display = run('/usr/bin/codesign', '-dvvv', path)
    values = dict(line.split('=', 1) for line in display.splitlines() if '=' in line)
    ent, _ = run('/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', path)
    return {'path': str(path), 'sha256': sha(path) if path.is_file() else None,
            'cdhash': values.get('CDHash'), 'identifier': values.get('Identifier'),
            'info_plist_binding': values.get('Info.plist'),
            'entitlements': plistlib.loads(ent.encode()) if ent.strip() else {}}

artifacts = {}
for name, path in [('cli_app', app), ('launchpad_app', launchpad), ('local_core_bundle', bundle)]:
    plist = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    closure = native.check_native_dependencies(path)
    executables = {}
    for relative in native.HOST_EXECUTABLES:
        p = path / relative
        if p.exists(): executables[relative] = signature(p)
    run('/usr/bin/codesign', '--verify', '--strict', '--deep', path)
    artifacts[name] = {'path': str(path), 'info_plist': plist, 'native_closure': closure,
                       'executables': executables, 'full_signature_verified': True}
    if (path / 'Contents/Helpers/vphone-cli.app').exists():
        helper = path / 'Contents/Helpers/vphone-cli.app'
        artifacts[name]['embedded_cli'] = signature(helper / 'Contents/MacOS/vphone-cli')
        artifacts[name]['embedded_vm'] = signature(helper / 'Contents/MacOS/vphone-vm')
vm = 'Contents/MacOS/vphone-vm'
assert artifacts['cli_app']['executables'][vm]['sha256'] == artifacts['local_core_bundle']['executables'][vm]['sha256']
assert artifacts['launchpad_app']['embedded_vm']['sha256'] == artifacts['cli_app']['executables'][vm]['sha256']
record = {'source': source, 'source_digest': source_digest, 'version': version,
          'version_provenance': 'B39 research packaging identifier; not an upstream release claim',
          'packaging_info_changes': changes, 'archive': str(archive), 'archive_sha256': sha(archive),
          'store_target': '/Library/Application Support/vphone-launchpad/Bundles/' + version,
          'artifacts': artifacts}
(HERE / 'frozen-candidates.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
print(json.dumps({'version': version, 'archive_sha256': record['archive_sha256'],
                  'vm_cdhash': artifacts['cli_app']['executables'][vm]['cdhash'],
                  'closure_sizes': {name: len(x['native_closure']) for name, x in artifacts.items()}}))

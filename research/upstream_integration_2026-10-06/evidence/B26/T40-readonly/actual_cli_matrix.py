"""Production CLI probes using temporary 0 GiB VM fixtures; never boots a VM.

This verifies refusal and persistent byte transfer only. Constructed binding
fields and a copied historical host receipt establish no current runtime trust.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--cli', required=True, type=Path)
p.add_argument('--receipt', required=True, type=Path)
p.add_argument('--output', required=True, type=Path)
a = p.parse_args()
a.output = a.output.absolute()
assert str(a.output).startswith('/private/tmp/vphone-b26-t40/'), a.output
a.output.mkdir(mode=0o700, parents=False, exist_ok=False)
store = Path('/Library/Application Support/vphone-launchpad/Bundles')
assert not store.exists() and not store.is_symlink(), 'This refusal matrix requires the store absent; no store will be changed.'
env = dict(os.environ, VPHONE_ROOT=str(a.output/'user-root'), PYTHONDONTWRITEBYTECODE='1')
report = {'scope': 'actual final CLI; synthetic 0 GiB VM fixtures only; no VM/store/system mutation',
          'cli': str(a.cli.resolve()), 'cli_sha256': hashlib.file_digest(a.cli.open('rb'), 'sha256').hexdigest(),
          'store_before': 'absent', 'commands': [], 'refusals': [], 'transfers': [], 'task_accepted': False,
          'limitations': ['No real VM archive, restore, boot or component update',
                         'Binding inputs are constructed fixtures; no actual component source established',
                         'Historical receipt bytes are opaque; this does not verify current trusted root store',
                         'Code lower bound acceptance does not establish cross-series compatibility']}

def save():
    (a.output/'result.json').write_text(json.dumps(report, indent=2)+'\n')

def run(label, args, success=True):
    assert args[0] in ['vm', 'resources', 'core-bundle', 'fw', 'cfw', 'guest', '--help']
    if args[0] == 'vm':
        assert args[1] in ['new', 'bind-core-bundle', 'clone', 'rename', 'export', 'import', 'info', '--help']
    elif args[0] == 'core-bundle':
        assert args[1] in ['verify', '--help']
    elif args[0] in ['fw', 'cfw', 'guest']:
        assert args == [args[0], '--help']
    start = time.monotonic()
    r = subprocess.run([str(a.cli), *args], env=env, capture_output=True, timeout=120)
    index = len(report['commands'])
    stem = f'{index:03d}-{label}'
    (a.output/(stem+'.stdout')).write_bytes(r.stdout)
    (a.output/(stem+'.stderr')).write_bytes(r.stderr)
    report['commands'].append({'label': label, 'argv': args, 'returncode': r.returncode,
                               'seconds': time.monotonic()-start, 'stdout': stem+'.stdout', 'stderr': stem+'.stderr'})
    save()
    assert (r.returncode == 0) == success, (label, r.returncode, r.stderr)
    return r

def inventory(root):
    assert root.is_relative_to(a.output)
    result = {}
    for f in sorted(root.rglob('*')):
        rel = str(f.relative_to(root))
        if rel in ['.vphone-runtime.json', 'vphone.sock']:
            continue
        s = f.lstat()
        row = {'mode': stat.S_IMODE(s.st_mode)}
        if stat.S_ISREG(s.st_mode):
            row.update(kind='file', bytes=s.st_size, sha256=hashlib.file_digest(f.open('rb'), 'sha256').hexdigest())
        elif stat.S_ISLNK(s.st_mode):
            row.update(kind='link', target=os.readlink(f))
        else:
            continue
        result[rel] = row
    return result

for args in [['--help'], ['resources'], ['vm', '--help'], ['fw', '--help'], ['cfw', '--help'], ['guest', '--help']]:
    run('read-only-help' if '--help' in args else 'resources', args)
library = a.output/'library'
library.mkdir(mode=0o700)
rom = a.output/'synthetic-ROM.bin'
rom.write_bytes(b'SYNTHETIC ROM - NOT BOOTABLE\n')
run('new-0GiB-fixture', ['vm', 'new', '--library-root', str(library), 'source', '--disk-size', '0', '--rom', str(rom), '--seprom', str(rom)])
machine = library/'source'
binding = machine/'launchpad.json'
base = inventory(machine)
legacy = {'bundle': '2.6.1-local.1208708c55574677', 'guestEnvironment': '2.6.0', 'bootChain': '2.6.0-ci.abcdef0'}
four = dict(legacy, kernel='2.6.1')
versions = [
    ('release-lower-bound', '2.6.0', 'unavailable or failed verification'),
    ('patch-different', '2.6.2', 'unavailable or failed verification'),
    ('local-suffix', '2.6.1-local.1208708c55574677', 'unavailable or failed verification'),
    ('ci-suffix', '2.6.0-ci.abcdef0', 'unavailable or failed verification'),
    ('cross-series-code-bound-only', '2.7.0', 'unavailable or failed verification'),
    ('below-code-bound', '2.5.9', '2.6.0 or later'),
    ('invalid-version', '../2.6.1', '2.6.0 or later'),
]
for name, version, expected in versions:
    before = inventory(machine)
    backup = a.output/('backup-'+name)
    r = run(name, ['vm', 'bind-core-bundle', '--library-root', str(library), 'source', '--version', version, '--backup', str(backup)], False)
    assert expected in r.stderr.decode(), (name, r.stderr)
    assert inventory(machine) == before and not backup.exists()
    report['refusals'].append({'case': name, 'machine_unchanged': True, 'backup_absent': True, 'expected_error': expected})

for name, content in [('legacy-three-field', legacy), ('four-field', four), ('invalid-origin', dict(four, kernel='../2.6.1'))]:
    binding.write_text(json.dumps(content)+'\n')
    os.chmod(binding, 0o600)
    before = inventory(machine)
    r = run('rebind-'+name, ['vm', 'bind-core-bundle', '--library-root', str(library), 'source', '--version', '2.6.2'], False)
    expected = 'Invalid Core Bundle origin' if name == 'invalid-origin' else 'Restore this exact verified version'
    assert expected in r.stderr.decode(), (name, r.stderr)
    assert inventory(machine) == before
    report['refusals'].append({'case': 'rebind-'+name, 'machine_unchanged': True, 'expected_error': expected})
binding.unlink()
assert inventory(machine) == base

receipt = a.receipt.read_bytes()
report['historical_receipt'] = {'input': str(a.receipt), 'sha256': hashlib.sha256(receipt).hexdigest(),
                                'provenance': 'B22 actual install stdout copied in B24; no current store authorization'}
for backend in ['native', 'system-tar']:
    for fixture, content in [('missing-binding', None), ('legacy-three-field', legacy), ('four-field', four)]:
        if binding.exists():
            binding.unlink()
        if content is not None:
            binding.write_text(json.dumps(content, sort_keys=True)+'\n')
            os.chmod(binding, 0o600)
        historical = machine/'acceptance-host-receipt-copy.json'
        historical.write_bytes(receipt)
        os.chmod(historical, 0o600)
        state = machine/'state.bin'
        state.write_bytes(b'SYNTHETIC persistent state\n')
        os.chmod(state, 0o640)
        before = inventory(machine)
        name = f'{backend}-{fixture}'
        renamed = name+'-renamed'
        imported = name+'-imported'
        run(name+'-clone', ['vm', 'clone', '--library-root', str(library), 'source', name])
        assert inventory(library/name) == before
        run(name+'-rename', ['vm', 'rename', '--library-root', str(library), name, renamed])
        assert not (library/name).exists() and inventory(library/renamed) == before
        archive = a.output/(name+'.txz')
        run(name+'-export', ['vm', 'export', '--library-root', str(library), renamed, '--out', str(archive), '--max', '--archive-backend', backend])
        run(name+'-import', ['vm', 'import', '--library-root', str(library), str(archive), '--name', imported, '--archive-backend', backend])
        assert inventory(library/imported) == before and inventory(machine) == before
        report['transfers'].append({'case': name, 'inventory': before, 'archive_bytes': archive.stat().st_size,
                                    'binding_present_after': (library/imported/'launchpad.json').exists(),
                                    'identical': True, 'receipt_authenticated': False})
        save()
assert not store.exists() and not store.is_symlink()
assert hashlib.file_digest(a.cli.open('rb'), 'sha256').hexdigest() == report['cli_sha256']
report.update(complete=True, store_after='absent', cli_unchanged=True, vm_started=False)
save()
print(json.dumps({'complete': True, 'commands': len(report['commands']), 'refusals': len(report['refusals']),
                  'transfer_rows': len(report['transfers']), 'result': str(a.output/'result.json')}))

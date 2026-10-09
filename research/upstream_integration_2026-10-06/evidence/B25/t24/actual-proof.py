import hashlib, json, plistlib, subprocess
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
base=Path('/private/tmp/vphone-b25-t24')
app=base/'portable-vphone-cli.app'
report={'scope':'Signed host Mach-O closure only; Python/PATH dependencies and TCC authorization are not established.', 'commands':[]}
def run(args, **kwargs):
    result=subprocess.run([str(a) for a in args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    record={'argv':[str(a) for a in args], 'exit_code':result.returncode, 'stdout':result.stdout, 'stderr':result.stderr}
    report['commands'].append(record)
    return result
for name in ('build_native_dependencies.py','check_bundle.py','check_launchpad_bundle.py','record_build_dependencies.py','build.sh'):
    (app/'Contents/Resources/scripts'/name).write_bytes((root/'scripts'/name).read_bytes())
assert run(['codesign','--force','--sign','-',app]).returncode == 0
assert run(['python3',root/'scripts/record_build_dependencies.py',app],cwd=root).returncode == 0
assert run(['codesign','--force','--sign','-',app]).returncode == 0
assert run(['python3',root/'scripts/check_bundle.py',app],cwd=root).returncode == 0
assert run(['codesign','--verify','--strict','--deep',app]).returncode == 0
for path in [app/'Contents/MacOS/ldid', app/'Contents/Resources/.tools/bin/trustcache', *sorted((app/'Contents/Frameworks').iterdir())]:
    assert run(['otool','-L',path]).returncode == 0
    assert run(['otool','-D',path]).returncode == 0
    assert run(['codesign','--verify','--strict',path]).returncode == 0
    run(['codesign','-dvvv',path])
sandbox=['/usr/bin/sandbox-exec','-f',base/'homebrew-denied.sb']
# Prove the denying profile rejects the original Homebrew library paths.
assert run([*sandbox,'/bin/cat','/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib']).returncode != 0
ldid=run([*sandbox,app/'Contents/MacOS/ldid','-e',app/'Contents/Resources/guest-resources/vphoned'])
assert ldid.returncode == 0
plistlib.loads(ldid.stdout.encode())
assert run([*sandbox,app/'Contents/Resources/.tools/bin/trustcache','create','-v','1',base/'portable.trustcache',app/'Contents/Resources/guest-resources/vphoned']).returncode == 0
assert run([*sandbox,app/'Contents/Resources/.tools/bin/trustcache','info',base/'portable.trustcache']).returncode == 0
report['guest_sha256']=hashlib.sha256((app/'Contents/Resources/guest-resources/vphoned').read_bytes()).hexdigest()
report['files']={str(path.relative_to(app)):hashlib.sha256(path.read_bytes()).hexdigest() for path in [app/'Contents/MacOS/vphone-cli',app/'Contents/MacOS/vphone-vm',app/'Contents/MacOS/ldid',app/'Contents/Resources/.tools/bin/trustcache',*sorted((app/'Contents/Frameworks').iterdir())]}
(base/'actual-proof.json').write_text(json.dumps(report,indent=2)+'\n')
print('Actual bundle, per-image signatures, original-path denial and ldid/trustcache operations passed')

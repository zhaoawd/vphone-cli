#!/usr/bin/env python3
"""Replay the preserved T52 launchd signer collision without touching a VM."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from patchers import component_signatures as signatures

work = ROOT / '.build/t52-real-20261021/signing-repro-verified'
work.mkdir(exist_ok=True)
store = ROOT / '.build/t51rt/lib/t52-v2/.cfw-history/20261021T150033Z-LgvNNC6B/effect-blobs'
original = store / '411d730c95d99a088e94b673eff3fa73d6d3cc778b24b476cd0b7866cd037443'
injected = store / '936f679ed6559993f7a08637e34d1d93726756f47461774bfc34a4d05d0de0e3'
for path in (original, injected):
    assert hashlib.sha256(path.read_bytes()).hexdigest() == path.name
ldid = shutil.which('ldid')
assert ldid, 'ldid unavailable'
ents = work / 'entitlements.plist'
ents.write_bytes(subprocess.check_output([ldid, '-e', str(original)]))
certificate = ROOT / '.build/t51rt/lib/t52-v2/cfw_input/signcert.p12'
commands = []

def sign(path):
    argv = [ldid, '-S' + str(ents), '-M', '-K' + str(certificate), str(path)]
    subprocess.run(argv, check=True)
    commands.append(argv)

bad = work / 'unreserved-signed'
shutil.copy2(injected, bad)
sign(bad)
try:
    signatures.verify_signing(injected, bad)
except ValueError as error:
    assert str(error) == 'signature load command overwrote non-padding bytes'
    rejection = str(error)
else:
    raise AssertionError('Original collision was not detected')
prepared = work / 'prepared'
shutil.copy2(injected, prepared)
assert signatures.reserve_signature_command(prepared)
content = signatures.layouts(injected)[0]['end']
assert prepared.read_bytes()[content:] == injected.read_bytes()[content:]
final = work / 'reserved-signed'
shutil.copy2(prepared, final)
sign(final)
signatures.verify_signing(prepared, final)
assert signatures.entitlements(final) == signatures.entitlements(original)
assert final.read_bytes()[content:injected.stat().st_size] == injected.read_bytes()[content:]
result = dict(state='passed', originalRejection=rejection, executableBytesPreserved=True,
              entitlementsPreserved=True, finalCodeDirectoryPagesVerified=True,
              contentStart=content, preparedEnd=signatures.layouts(prepared)[0]['end'],
              signedEnd=signatures.layouts(final)[0]['end'], commands=commands)
(work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))

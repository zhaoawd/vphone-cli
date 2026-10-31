"""Synthetic mixed-device history using real file publication and Undo proofs.

Only disposable fixture records are rewritten to model a device-number change.
No production history or real VM is used. The child journal keeps native st_dev.
"""
import hashlib
import json
import os
from pathlib import Path
import runpy
import sys

ROOT = Path(__file__).resolve().parents[1]
vm = Path(sys.argv[1])
runpy.run_path(str(ROOT / 'tests/cfw_file_identity_bridge_fixture.py'), run_name='__main__')


def read(path):
    return json.loads(path.read_bytes())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.chmod(0o600)
    path.write_text(json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n')


archives = list((vm / '.cfw-history').iterdir())
first, = [p for p in archives if p.name.endswith('fileidentity1')]
child, = [p for p in archives if p.name.endswith('fileidentity2')]
record = read(first / 'transaction.json'); checkpoint = read(first / 'guest-publication.json')
old_checkpoint = sha(first / 'guest-publication.json')
actual_dev = (child / 'Disk.img').stat().st_dev
historical_dev = actual_dev + 1
members = []
for path, old in ((child / 'Disk.img', checkpoint['imageIdentity']),
                  (first / 'guest-postimage.img', checkpoint['postimageIdentity'])):
    info = path.stat()
    current = dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size, mtime_ns=info.st_mtime_ns)
    members.append(dict(paths=[str(path.relative_to(vm))], recorded=dict(current, dev=historical_dev),
                        current=current, sha256=sha(path)))
record['staged']['dev'] = historical_dev
for key in ('imageIdentity', 'runtimeIdentity', 'postimageIdentity'):
    checkpoint[key]['dev'] = historical_dev
final = read(first / 'guest-effects-final.json'); final['stagedIdentity']['dev'] = historical_dev
write(first / 'guest-effects-final.json', final)
checkpoint['files']['guest-effects-final.json'] = sha(first / 'guest-effects-final.json')
record['undoProvenance']['finalProofSHA256'] = checkpoint['files']['guest-effects-final.json']
write(first / 'guest-publication.json', checkpoint)
record['guestEvidenceSHA256'] = sha(first / 'guest-publication.json'); write(first / 'transaction.json', record)

# Update the fixture child's sealed parent link, retaining its actual device.
request = read(child / 'guest-undo-request.json')
assert request['parentCheckpointSHA256'] == old_checkpoint
request['parentCheckpointSHA256'] = record['guestEvidenceSHA256']
write(child / 'guest-undo-request.json', request)
child_record = read(child / 'transaction.json'); child_checkpoint = read(child / 'guest-publication.json')
assert child_record['original']['dev'] == actual_dev
child_record['guestUndoRequestSHA256'] = sha(child / 'guest-undo-request.json')
child_checkpoint['files']['guest-undo-request.json'] = child_record['guestUndoRequestSHA256']
write(child / 'guest-publication.json', child_checkpoint)
child_record['guestEvidenceSHA256'] = sha(child / 'guest-publication.json')
write(child / 'transaction.json', child_record)
(vm / 'mixed-reboot-fixture.json').write_text(json.dumps(dict(members=members, postimage=str(first / 'guest-postimage.img'))))
print(json.dumps(dict(state='mixed-device-child-retains-native-identity', realVMWrites=0)))

"""Read stopped Task 8 metadata and freeze expectations for the same-kernel reboot."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess

E = Path(__file__).resolve().parent
R = E.parents[3]
VM = Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
LABEL = 'kernel-v9-documents-reboot-a'
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
record = dict(passed=False, label=LABEL)
try:
    for suffix in ('-pre-boot-check.json', '-boot-expectations.json'):
        assert not os.path.lexists(E / (LABEL + suffix))
    for name in ('.firmware-transaction', '.firmware-desired-pending.json'):
        assert not os.path.lexists(VM / name)
    processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True, timeout=10)
    relevant = [line for line in processes.splitlines()
                if ('/vphone-vm ' in line and 'vphone-task8-acceptance-vms/task8-copy/config.plist' in line)
                or str(E / 'scoped-amfi-v4') in line]
    assert not relevant, relevant
    images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist'], timeout=10))
    attached = [image for image in images.get('images', []) if 'vphone-task8-acceptance-vms' in image.get('image-path', '')]
    assert not attached
    for suffix in ('-vm-launch.json', '-vm-stop.json'):
        assert json.loads((E / ('kernel-v9-rollback-a' + suffix)).read_text())['exit_code'] == 0
    assert json.loads((E / 'kernel-v9-rollback-a-post-boot-cleanup.json').read_text())['passed'] is True
    expected_raw = (E / 'kernel-v9-rollback-a-boot-expectations.json').read_bytes()
    expected = json.loads(expected_raw)
    for name, key in [('launchpad.json', 'binding_sha256'), ('.firmware-component-receipts.json', 'receipt_sha256'), ('.firmware-desired-plan.json', 'desired_sha256')]:
        assert sha(VM / name) == expected[key]
    assert json.loads((VM / 'launchpad.json').read_text()) == expected['binding']
    marker = json.loads((E / 'kernel-v9-rollback-a-persistent-marker-v2-create.json').read_text())
    assert marker['passed'] is True and marker['downloaded_size'] == 1254
    assert marker['downloaded_sha256'] == 'a8faa4e5b805fd5a0ee0f8330296d168bb85f33c674748595d176df3714e418e'
    old_failure = E / 'kernel-v9-rollback-a-marker-read.json'
    assert json.loads(old_failure.read_text())['passed'] is False
    frozen = json.loads((E / 'kernel-rollback/manifest.json').read_text())['sourceFiles']
    assert len(frozen) == 16
    for item in frozen: assert sha(R / item['path']) == item['sha256']
    v4 = json.loads((E / 'core-candidate-v4-manifest.json').read_text())
    base = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS')
    for name in ('vphone-cli', 'vphone-vm'): assert sha(base / name) == v4['artifacts'][name]['sha256']
    cli9 = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.20261021-local/VPhone.bundle/Contents/MacOS/vphone-cli')
    assert sha(cli9) == 'e1c6ca75c19966ec8bcada05ca235c1e5019c572570b64e8ebed041f0d14da76'
    spec = importlib.util.spec_from_file_location('amfid_observation', E / 'restore-acceptance-amfid.py')
    module = importlib.util.module_from_spec(spec)
    import sys
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    amfid = []
    for line in processes.splitlines():
        pieces = line.strip().split(None, 1)
        if len(pieces) == 2 and pieces[1] == '/usr/libexec/amfid':
            observation = module.NativeOperations().observe(int(pieces[0]))
            assert observation['bsd_state'] == module.SRUN, observation
            amfid.append(observation)
    with (E / (LABEL + '-boot-expectations.json')).open('xb') as output: output.write(expected_raw)
    record.update(passed=True, expected=expected, old_marker_failure_sha256=sha(old_failure),
                  persistent_create_sha256=sha(E / 'kernel-v9-rollback-a-persistent-marker-v2-create.json'),
                  amfid_observation=amfid, signals_sent=[], task8_processes=relevant, task8_attachments=attached,
                  pending=False, frozen_source16=True, frozen_v9_cli=True, frozen_v4_cli_vm=True,
                  limitation='No disk-content hash or marker observation; restart read is still pending')
finally:
    os.close(fd)
    with (E / (LABEL + '-pre-boot-check.json')).open('x') as output:
        json.dump(record, output, indent=2); output.write('\n')
print(json.dumps(record))

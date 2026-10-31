#!/usr/bin/env python3
"""Capture read-only before/after reports from the approved installed Bundle."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('phase', choices=('before', 'after'))
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-real-20261021'
resources = Path('/Library/Application Support/vphone-launchpad/Bundles/'
                 '2.6.2-local.cd529f26a150/VPhone.bundle/Contents/Resources')
name = args.phase
attempt = 1
while (work / f'environment-{name}.json').exists():
    attempt += 1
    name = f'{args.phase}-{attempt}'
report = work / f'environment-{name}.json'
argv = [str(root / '.venv/bin/python3'), '-B',
        str(resources / 'scripts/cfw_env_update.py'), 'check-vm',
        str(root / '.build/t51rt/lib/t52-v2'), '--components',
        str(resources / '.build/guest-components-v2/stage'), '--report', str(report)]
started = time.time()
result = subprocess.run(argv, capture_output=True, text=True)
(work / f'environment-{name}.stdout.log').write_text(result.stdout)
(work / f'environment-{name}.stderr.log').write_text(result.stderr)
record = dict(argv=argv, startedAt=started, endedAt=time.time(), exitCode=result.returncode)
(work / f'environment-{name}-invocation.json').write_text(json.dumps(record, indent=2) + '\n')
if result.returncode:
    print(json.dumps(record, indent=2))
    print(result.stderr)
    raise SystemExit(result.returncode)
envelope = json.loads(report.read_text())
value = envelope['report']
metadata = subprocess.run([str(root / '.venv/bin/python3'), '-B',
    str(Path(__file__).with_name('capture_t52_vm_metadata.py')),
    str(work / f'metadata-{name}.json')], capture_output=True, text=True)
if metadata.returncode:
    print(metadata.stderr)
    raise SystemExit(metadata.returncode)
print(json.dumps(dict(phase=args.phase, classification=value['classification'],
    replace=value['replace'], disk=value['disk'], report=str(report)), indent=2))

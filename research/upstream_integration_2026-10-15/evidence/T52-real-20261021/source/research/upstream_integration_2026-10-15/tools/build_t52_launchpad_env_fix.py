#!/usr/bin/env python3
"""Assemble an isolated Launchpad repair, preserving the approved helper bytes."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[3]
old = root / '.build/t52-entrypoints-launchpad-20261021.app'
new = root / '.build/t52-envfix-launchpad-20261022.app'
if new.exists():
    raise SystemExit('Preserve the existing candidate; choose a new build path')
subprocess.run(['/usr/bin/ditto', str(old), str(new)], check=True)
shutil.copy2(root / '.build/release/vphone-launchpad', new / 'Contents/MacOS/vphone-launchpad')
subprocess.run([str(root / '.venv/bin/python3'), '-B', str(root / 'scripts/build_native_dependencies.py'), str(new)], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'com.vphone.cli.launchpad', str(new)], check=True)
subprocess.run([str(root / '.venv/bin/python3'), '-B', str(root / 'scripts/check_launchpad_bundle.py'),
    str(new), '--reference', str(old / 'Contents/Helpers/vphone-cli.app')], check=True)
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
unchanged = {}
for name in ('vphone-cli', 'vphone-vm'):
    relative = Path('Contents/Helpers/vphone-cli.app/Contents/MacOS') / name
    unchanged[name] = digest(old / relative) == digest(new / relative)
assert all(unchanged.values())
record = dict(app=str(new), outerSHA256=digest(new / 'Contents/MacOS/vphone-launchpad'),
    approvedEmbeddedExecutablesUnchanged=unchanged,
    fix='Inherit parent environment when no explicit child environment is supplied',
    tests='23 related Swift tests passed; original inheritance test failed before fix')
(root / '.build/t52-real-20261021/launchpad-env-fix-candidate.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, indent=2))

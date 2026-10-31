#!/usr/bin/env python3
"""Approved amended System stage; encrypted Data is left to guest-side cache transition."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-consumer-fix-20261022'
CONFIGURATION_SHA256 = 'ae590a5e8568315f175cd7ad9f9d23d16c30d0c3809b9edafe0f71cf7b74c4f7'


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    if sys.argv[1:] != ['--execute-approved-amended-plan'] or os.geteuid() != 0:
        raise ValueError('Explicit amended-plan approval and administrator authentication required')
    configuration = WORK / 'system-root-configuration.json'
    if digest(configuration) != CONFIGURATION_SHA256:
        raise ValueError('Frozen amended configuration changed')
    config = json.loads(configuration.read_text())
    for name, expected in config['frozenTools'].items():
        if digest(name) != expected: raise ValueError('Frozen tool changed: ' + name)
    if (WORK / 'system-maintenance-plan.json').exists() or (WORK / 'boot-window/authorization-window.json').exists():
        raise ValueError('Preserve prior transaction/window state; do not replay')
    source = ROOT / 'research/upstream_integration_2026-10-15/tools/t52_system_consumer_maintenance.py'
    spec = importlib.util.spec_from_file_location('t52_system_consumer_transaction', source)
    maintenance = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(maintenance)
    vm = Path(config['vm'])
    resources = maintenance.STORE / config['version'] / 'VPhone.bundle/Contents/Resources'
    lock = os.open(vm, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = maintenance.check_current(vm, resources, Path('/private/tmp'))
        maintenance.save(WORK / 'system-precheck.json', before)
        plan = maintenance.prepare(vm, resources, before)
        maintenance.save(WORK / 'system-maintenance-plan.json', plan)
        result = maintenance.apply_plan(plan, vm, resources, Path('/private/tmp'))
        maintenance.save(WORK / 'system-maintenance-result.json', result)
        after = maintenance.check_current(vm, resources, Path('/private/tmp'), after=True)
        if after['classification'] != 'already_current' or after['replace']:
            raise ValueError('Independent System read-only postcheck differs')
        after['publisherCacheTransition'] = 'pending_guest_side'
        maintenance.save(WORK / 'system-postcheck.json', after)
        maintenance.save(WORK / 'postcheck.json', after)
    finally:
        os.close(lock)
    # The window starts after System publication/read-back. Cache transition
    # happens only after boot and independent helper termination verification.
    with (WORK / 'system-root-window-start.log').open('x') as stream:
        subprocess.run(['/usr/bin/python3', '-u', str(WORK / 'boot-window/scoped-amfidont.py')],
                       stdout=stream, stderr=subprocess.STDOUT, check=True)


if __name__ == '__main__': main()

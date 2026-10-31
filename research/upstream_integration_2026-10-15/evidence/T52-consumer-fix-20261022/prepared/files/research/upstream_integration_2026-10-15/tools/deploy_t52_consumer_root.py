#!/usr/bin/env python3
"""Execute the concrete T52 plan only after explicit approval and root authentication."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-consumer-fix-20261022'
CONFIGURATION_SHA256 = 'a94adbaa46e1ad64c45fe1003410440e1c2d366ad2013d1b6bccc202f585e82c'


def digest(path):
    with open(path, 'rb') as stream:
        result = hashlib.sha256()
        for block in iter(lambda: stream.read(1 << 20), b''):
            result.update(block)
        return result.hexdigest()


def main():
    if sys.argv[1:] != ['--execute-approved-plan'] or os.geteuid() != 0:
        raise ValueError('Explicit plan approval and administrator authentication required')
    configuration = WORK / 'root-configuration.json'
    if digest(configuration) != CONFIGURATION_SHA256:
        raise ValueError('Frozen root configuration changed')
    config = json.loads(configuration.read_text())
    for name, expected in config['frozenTools'].items():
        if digest(name) != expected:
            raise ValueError('Frozen tool changed: ' + name)
    if digest(config['checker']) != config['checkerSHA256'] or digest(config['archive']) != config['archiveSHA256']:
        raise ValueError('Installer or candidate archive changed')
    if (WORK / 'binding-ready.json').exists() or (WORK / 'root-install-receipt.json').exists():
        raise ValueError('Preserve previous run state; this transaction cannot be replayed')
    checker, version = config['checker'], config['version']
    with (WORK / 'root-install-receipt.json').open('x') as stream:
        subprocess.run([checker, 'core-bundle', 'install', '--version', version, '--archive', config['archive'],
                        '--sha256', config['archiveSHA256']], stdout=stream, check=True)
    with (WORK / 'root-verified-receipt.json').open('x') as stream:
        subprocess.run([checker, 'core-bundle', 'verify', '--version', version], stdout=stream, check=True)
    deadline = time.monotonic() + 900
    while not (WORK / 'binding-ready.json').exists():
        if time.monotonic() >= deadline:
            raise TimeoutError('Normal VM stop and host binding did not become ready; no disk or window action')
        time.sleep(.25)
    ready = json.loads((WORK / 'binding-ready.json').read_text())
    if ready != {'vm': config['vm'], 'bundle': version, 'previousInstanceID': config['priorInstanceID']}:
        raise ValueError('Stopped target/binding readiness differs')
    source = ROOT / 'research/upstream_integration_2026-10-15/tools/t52_consumer_maintenance.py'
    spec = importlib.util.spec_from_file_location('t52_consumer_transaction', source)
    maintenance = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(maintenance)
    import fcntl
    vm = Path(config['vm'])
    lock = os.open(vm, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        resources = maintenance.STORE / version / 'VPhone.bundle/Contents/Resources'
        before = maintenance.check_current(vm, resources, Path('/private/tmp'))
        maintenance.save(WORK / 'precheck.json', before)
        plan = maintenance.prepare(vm, resources, before)
        maintenance.save(WORK / 'maintenance-plan.json', plan)
        result = maintenance.apply_plan(plan, vm, resources, Path('/private/tmp'))
        maintenance.save(WORK / 'maintenance-result.json', result)
        after = maintenance.check_current(vm, resources, Path('/private/tmp'), after=True)
        if after['classification'] != 'already_current' or after['replace']:
            raise ValueError('Independent read-only postcheck differs')
        maintenance.save(WORK / 'postcheck.json', after)
    finally:
        os.close(lock)
    # Start the new, separately supervised window only after the old disk has
    # been retained and both System and Data read-back have passed.
    with (WORK / 'root-window-start.log').open('x') as stream:
        subprocess.run(['/usr/bin/python3', '-u', str(WORK / 'boot-window/scoped-amfidont.py')],
                       stdout=stream, stderr=subprocess.STDOUT, check=True)


if __name__ == '__main__': main()

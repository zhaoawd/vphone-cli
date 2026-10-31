#!/usr/bin/env python3
"""Approved single-library provider stage; API and encrypted Data are unchanged."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-provider-fix-20261023'
CONFIGURATION_SHA256 = '81d23814629eb24e70e5e94a0c0273cb425e486f0d7326fda0050a87020f1c01'


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    if sys.argv[1:] != ['--execute-approved-provider-plan'] or os.geteuid() != 0:
        raise ValueError('Explicit provider-plan approval and administrator authentication required')
    configuration = WORK / 'root-configuration.json'
    if digest(configuration) != CONFIGURATION_SHA256:
        raise ValueError('Frozen provider configuration changed')
    config = json.loads(configuration.read_text())
    for name, expected in config['frozenTools'].items():
        if digest(name) != expected: raise ValueError('Frozen tool changed: ' + name)
    if (WORK / 'system-maintenance-plan.json').exists() or (WORK / 'boot-window/authorization-window.json').exists():
        raise ValueError('Preserve prior transaction/window state; do not replay')
    source = ROOT / 'research/upstream_integration_2026-10-15/tools/t52_provider_maintenance.py'
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
        after['publisherCacheTransition'] = 'unchanged_by_this_transaction'
        maintenance.save(WORK / 'system-postcheck.json', after)
        maintenance.save(WORK / 'postcheck.json', after)
    finally:
        os.close(lock)
        owner = os.stat(vm)
        for name in ['system-precheck.json', 'system-maintenance-plan.json', 'system-maintenance-result.json', 'system-postcheck.json', 'postcheck.json']:
            report = WORK / name
            if report.exists() and not report.is_symlink():
                os.chown(report, owner.st_uid, owner.st_gid, follow_symlinks=False)
    # Start the separately approved window only after publication/readback.
    # No API or publisher cache transition belongs to this transaction.
    with (WORK / 'system-root-window-start.log').open('x') as stream:
        subprocess.run(['/usr/bin/python3', '-u', str(WORK / 'boot-window/scoped-amfidont.py')],
                       stdout=stream, stderr=subprocess.STDOUT, check=True)


if __name__ == '__main__': main()

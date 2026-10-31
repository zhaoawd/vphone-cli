#!/usr/bin/env python3
"""Run one separately approved fresh EXP acceptance; never retry or boot."""
import argparse
import json
import os
from pathlib import Path

import execute_t32_producer_acceptance as base

ROOT = base.ROOT
WORK = ROOT / '.build/t32-t33-completion-20261023/exp-target-binding-acceptance-20261025'
VM = ROOT / '.build/t33s-20261025'
TARGETS = ['system:/System/Library/CoreServices/SystemVersion.plist',
           'system:/System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist']
RULES = 'cf03209f536f245fb775a5a146eaa6a769d6c427ec061c644b9a5a1bc67354a8'


def validate(plan):
    if (len(plan['targets']) != 1 or plan['targets'][0]['vm'] != str(VM)
            or plan['targets'][0]['variant'] != 'exp'
            or plan['targets'][0]['mode'] != 'fresh-copy-and-generation'
            or plan['targets'][0]['targets'] != TARGETS
            or plan['targets'][0]['declarations'] != ['system-systemversion-cfw-build_version']
            or plan['candidate']['targetRulesSHA256'] != RULES
            or plan['reuseLockedPythonRuntime'] is not True
            or any(plan[k] != 0 for k in ('VMStarts', 'normalGUIBoots', 'securityWindows'))
            or any(plan[k] is not False for k in ('automaticRetry', 'automaticRollback'))):
        raise ValueError('Fresh EXP acceptance scope changed')
    return plan


def configure(digest):
    base.WORK = WORK
    base.APPROVED_SHA256 = digest
    base.EXECUTOR_INPUTS = 'executor-inputs.json'


def unrelated(plan):
    for name, expected in plan['unrelatedDiskIdentities'].items():
        info = (ROOT / name).stat()
        if dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size) != expected:
            raise ValueError('Preserved disk identity changed: ' + name)


def preflight(plan, digest):
    validate(plan)
    base.approved(digest)
    base.require_capacity(plan)
    base.verify_inputs(plan)
    base.verify_execution_inputs()
    unrelated(plan)
    if any(os.path.lexists(p) for p in (VM, plan['targets'][0]['firstBindingBackup'],
                                       base.store_cli(plan).parents[3], WORK / 'execution')):
        raise ValueError('Preserve existing target, Store or execution; no replay')
    if base.target_attachments(plan):
        raise ValueError('Target attachment already present')
    return base.baseline(plan)


def execute(plan, digest):
    if os.geteuid() != 0:
        raise ValueError('Native administrator authentication required')
    preflight(plan, digest)
    out = WORK / 'execution'
    out.mkdir(mode=0o755)
    result = dict(state='failed', VMStarts=0, securityWindows=0, originalVMWritten=False, targets=[])
    env = base.runtime_environment(plan)
    try:
        candidate = plan['candidate']
        local = Path(candidate['bundle']) / 'Contents/MacOS/vphone-cli'
        base.run(plan['runtimeProbeCommand'], out / 'runtime-probe.log', env)
        if json.loads((out / 'runtime-probe.log').read_text()).get('ok') is not True:
            raise ValueError('Locked runtime probe failed')
        base.run([local, 'core-bundle', 'install', '--version', candidate['version'],
                  '--archive', candidate['archive'], '--sha256', candidate['archiveSHA256']],
                 out / 'store-install.log', env)
        cli = base.store_cli(plan)
        base.run([cli, 'core-bundle', 'verify', '--version', candidate['version']], out / 'store-verify.log', env)
        if base.evidence.digest(cli) != candidate['cliSHA256']:
            raise ValueError('Installed candidate CLI differs')
        # The shared producer runs all three phases exactly once, with independent
        # final-target audits and complete originals/strict reapplication checks.
        result['targets'].append(base.run_target(plan, plan['targets'][0], out / 'exp', env))
        result['state'] = 'offline-qualified-on-off-on-passed'
    except Exception as error:
        result['error'] = str(error)
    finally:
        try:
            result['baseline'] = base.baseline(plan)
            unrelated(plan)
            base.verify_inputs(plan)
            base.verify_execution_inputs()
            result['targetAttachments'] = base.target_attachments(plan)
            if result['targetAttachments']:
                raise ValueError('Target attachment retained; no forced cleanup')
        except Exception as error:
            result['state'] = 'failed'
            result['preservationOrCleanupError'] = str(error)
        base.save(out / 'result.json', result)
        print(json.dumps(result), flush=True)
    return 0 if result['state'] == 'offline-qualified-on-off-on-passed' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare-executor', action='store_true')
    group.add_argument('--execute-approved-plan')
    args = parser.parse_args()
    plan = validate(json.loads((WORK / 'offline-plan.json').read_bytes()))
    digest = base.evidence.digest(WORK / 'offline-plan.json')
    configure(digest)
    if args.prepare_executor:
        # Preparation reports an unmet capacity gate; execution still refuses it.
        base.verify_inputs(plan)
        inputs = base.execution_inputs(plan)
        for name in ('execute_t33_target_binding_acceptance.py', 'test_t33_target_binding_acceptance.py'):
            path = Path(__file__).with_name(name)
            inputs[str(path.resolve())] = base.evidence.digest(path)
        base.save(WORK / base.EXECUTOR_INPUTS, dict(planSHA256=digest, files=inputs))
        info = os.statvfs(ROOT)
        available = info.f_bavail * info.f_frsize
        print(json.dumps(dict(state='prepared-not-approved', planSHA256=digest, inputs=len(inputs),
                             availableBytes=available, capacityPassed=available >= plan['minimumInitialFreeBytes'])))
        return 0
    if args.execute_approved_plan != digest:
        raise ValueError('Wrong fresh EXP plan digest')
    return execute(plan, digest)


if __name__ == '__main__':
    raise SystemExit(main())

#!/usr/bin/env python3
"""Wait for the existing native run; verify and archive without retrying it."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import execute_t32_origin_identity_acceptance as runner

ROOT = runner.ROOT
WORK = runner.WORK
OUT = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/continuation-outcome-20261024'


def root_running(identity):
    result = subprocess.run(['/bin/ps', '-p', str(identity['rootPID']), '-o', 'lstart='],
                            capture_output=True, text=True, env=dict(os.environ, LC_ALL='C'))
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return False
    if result.returncode != 0 or result.stderr.strip() or result.stdout.strip() != identity['rootStart']:
        raise ValueError('Native root process identity changed or could not be read')
    return True


def wait_for_native(identity, timeout):
    deadline = time.monotonic() + timeout
    while root_running(identity):
        if time.monotonic() >= deadline:
            raise ValueError('Finalization wait expired; native run was not interrupted')
        time.sleep(5)
    path = WORK / 'execution/result.json'
    if not path.exists():
        raise ValueError('Native process ended without a saved result; do not retry')
    return json.loads(runner.base.evidence.read(path))


def check_phase_reports(plan, native):
    reports = {}
    for target in plan['targets']:
        folder = WORK / 'execution' / target['variant']
        phases = {}
        for phase in ('on', 'off', 'reapplied'):
            path = folder / (phase + '.json')
            if not path.exists():
                continue
            value = json.loads(runner.base.evidence.read(path))
            runner.base.verify_origin(plan, target, phase, value['sourceReceipt'], value['binding'])
            if (value['independentAudit']['passed'] is not True
                    or value['generationID'] != value['independentAudit']['generationID']
                    or value['transactionID'] != value['independentAudit']['transactionID']
                    or set(value['targets']) != set(target['targets'])):
                raise ValueError('Saved phase lacks the required independent evidence')
            phases[phase] = value
        if native['state'] == 'offline-qualified-on-off-on-passed':
            if set(phases) != {'on', 'off', 'reapplied'}:
                raise ValueError('Native success lacks three complete phase reports')
            transition = json.loads(runner.base.evidence.read(folder / 'transition.json'))
            if transition['passed'] is not True or transition['runtimeValidated'] is not False:
                raise ValueError('Missing strict transition acceptance')
            if phases['on']['targets'] != phases['reapplied']['targets']:
                raise ValueError('First on and reapplication differ')
            generation = phases['on']['generationID']
            if any(value['generationID'] != generation for value in phases.values()):
                raise ValueError('Generation changed between phases')
            if target['variant'] == 'regular' and generation != target['generationID']:
                raise ValueError('Regular did not reuse the approved generation')
        reports[target['variant']] = phases
    return reports


def preservation(plan, native):
    if (native.get('VMStarts') != 0 or native.get('securityWindows') != 0
            or native.get('originalVMWritten') is not False
            or native.get('baseline') != dict(files=10, fullReadbackPassed=True)
            or native.get('targetAttachments') != [] or 'preservationOrCleanupError' in native):
        raise ValueError('Native preservation or offline scope check failed')
    runner.base.approved(runner.PLAN_SHA)
    runner.base.verify_inputs(plan); runner.base.verify_execution_inputs()
    source = runner.base.baseline(plan)
    before = json.loads(runner.base.evidence.read(WORK / 'unrelated-disk-identities-before.json'))
    for name, expected in before.items():
        s = (ROOT / name).stat()
        if dict(dev=s.st_dev, ino=s.st_ino, size=s.st_size) != expected:
            raise ValueError('Unrelated disk identity changed: ' + name)
    if runner.base.target_attachments(plan):
        raise ValueError('Target attachment remains; no force cleanup')
    if (WORK / 'execution/regular-before-write-backup.json').exists():
        if native.get('regularBeforeWriteBackupVerified') is not True:
            raise ValueError('Root-only pre-write backup lacks final verification')
    return dict(sourceBaseline=source, frozenInputsVerified=len(plan['frozenInputs']),
                executionInputsVerified=len(json.loads(runner.base.evidence.read(WORK / runner.base.EXECUTOR_INPUTS))['files']),
                unrelatedDiskIdentitiesVerified=len(before), targetAttachments=[],
                preWriteBackupScope='native root full readback; private backup is not independently mounted or read by finalizer')


def archive(plan, native, phases, verified):
    OUT.mkdir()
    paths = [WORK / name for name in ('offline-plan.json', 'approval.json', 'human-approval-20261024.json',
        'continuation-executor-inputs.json', 'continuation-readonly-preflight.json',
        'native-launch-observation.json', 'unrelated-disk-identities-before.json',
        'run-approved-continuation.zsh', 'run-approved-continuation.applescript', 'root-execution.log')]
    paths += [path for path in (WORK / 'execution').rglob('*') if path.is_file() and path.suffix in ('.json', '.log')]
    for path in paths:
        target = OUT / 'files' / path.relative_to(WORK)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        if runner.base.evidence.digest(path) != runner.base.evidence.digest(target):
            raise ValueError('Archived execution evidence differs')
    for path in (Path(__file__), Path(runner.__file__), Path(runner.base.__file__)):
        shutil.copy2(path, OUT / path.name)
    result = dict(state='offline-continuation-finalized', nativeState=native['state'],
        offlineAcceptancePassed=native['state'] == 'offline-qualified-on-off-on-passed',
        accepted=False, runtimeValidated=False, VMStarts=0, securityWindows=0,
        planSHA256=runner.PLAN_SHA, preservation=verified,
        phaseTransactions={variant: {phase: row['transactionID'] for phase, row in values.items()}
                           for variant, values in phases.items()},
        nativeError=native.get('error'), archive=str(OUT),
        verificationLimits=['No VM runtime, display, AA.gl or application consumption acceptance',
                            'Private pre-write backup final readback is reported by native root executor'])
    (OUT / 'outcome.json').write_text(json.dumps(result, indent=2) + '\n')
    files = []
    for path in sorted(OUT.rglob('*')):
        if path.is_file():
            files.append(dict(path=str(path.relative_to(OUT)), bytes=path.stat().st_size,
                              sha256=runner.base.evidence.digest(path)))
    runner.base.save(OUT / 'manifest.json', dict(state=result['state'], accepted=False, files=files))
    result['archiveManifestSHA256'] = runner.base.evidence.digest(OUT / 'manifest.json')
    runner.base.save(WORK / 'continuation-finalization.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wait-for-existing-native-run', action='store_true', required=True)
    args = parser.parse_args()
    if OUT.exists() or (WORK / 'continuation-finalization.json').exists():
        raise ValueError('Preserve an existing finalization; do not rerun')
    plan = runner.plan_record(); runner.base.approved(runner.PLAN_SHA)
    identity = json.loads(runner.base.evidence.read(WORK / 'native-launch-observation.json'))
    state = dict(state='waiting-existing-native-run', rootPID=identity['rootPID'], planSHA256=runner.PLAN_SHA,
                 startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
    finalizer_digest = runner.base.evidence.digest(Path(__file__))
    runner.base.save(WORK / 'continuation-finalizer-start.json', state)
    try:
        native = wait_for_native(identity, 5 * 60 * 60)
        if runner.base.evidence.digest(Path(__file__)) != finalizer_digest:
            raise ValueError('Finalizer source changed while waiting')
        phases = check_phase_reports(plan, native)
        verified = preservation(plan, native)
        result = archive(plan, native, phases, verified)
        report = ROOT / 'research/upstream_integration_2026-10-15/T32_T33_continuation_outcome_20261024.md'
        text = ('# T32/T33 续验结果（2026-10-24）\n\n'
                + '原生结果：`' + native['state'] + '`。离线验收通过：`' + str(result['offlineAcceptancePassed']).lower() + '`。\n\n'
                + '完整阶段事务：\n\n```json\n' + json.dumps(result['phaseTransactions'], indent=2) + '\n```\n\n'
                + '独立收尾复核了源备份10项完整内容和身份、571项计划输入、94项执行输入、12项无关磁盘身份及目标无附件。'
                + 'root私有写前备份依据原生执行器最终完整读回报告；收尾程序没有重新读取该私有目录。\n\n'
                + ('原生错误：`' + native['error'] + '`。按计划失败停止，没有重试或回滚。\n\n' if 'error' in native else '')
                + '本轮VMStarts=0、securityWindows=0。真实显示、AA.gl、应用消费及补丁运行效果仍待验收，整项accepted=false。旧失败和原始证据保持。\n\n'
                + '证据：`' + str(OUT.relative_to(ROOT)) + '/manifest.json`。\n')
        with report.open('x') as output:
            output.write(text)
        with (ROOT / 'TASKS.md').open('a') as output:
            output.write('\n\n2026-10-24 续验收尾：' + native['state'] + '；离线验收通过=' + str(result['offlineAcceptancePassed'])
                         + '。源备份10项完整读回、571/94项冻结输入、12项无关磁盘身份及目标无附件通过；root私有写前备份依据原生最终完整读回。'
                         + '阶段事务及限制见T32_T33_continuation_outcome_20261024.md；真实运行仍待验收，accepted=false。无重试/回滚/VM启动/辅助窗口。\n')
        print(json.dumps(result), flush=True)
        return 0
    except Exception as error:
        runner.base.save(WORK / 'continuation-finalization-stopped.json',
                         dict(state='finalization-stopped', error=str(error), nativeRunNotRetried=True))
        raise


if __name__ == '__main__':
    raise SystemExit(main())

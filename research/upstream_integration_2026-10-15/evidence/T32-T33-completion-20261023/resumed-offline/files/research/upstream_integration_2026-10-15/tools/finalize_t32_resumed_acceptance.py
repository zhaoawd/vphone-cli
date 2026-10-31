#!/usr/bin/env python3
"""Finish evidence for the existing native run; never start or repeat a VM operation."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t32-t33-completion-20261023'
TOOLS = Path(__file__).parent
RESEARCH = TOOLS.parent
PLAN_SHA = 'ba1279954c64ab30712e0e92eb4428c2b222f91d0cf9e621a39ad358f6d7fd95'
NATIVE_PID = 50959
RESULT = WORK / 'resumed-offline-acceptance/result.json'
STATE = WORK / 'resumed-finalization.json'
ARCHIVE = RESEARCH / 'evidence/T32-T33-completion-20261023/resumed-offline/manifest.json'
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_guest_evidence as evidence


def process():
    response = subprocess.run(['/bin/ps', '-p', str(NATIVE_PID), '-o', 'pid=,lstart=,command='],
                              capture_output=True, text=True, timeout=10)
    if response.returncode == 1 and not response.stdout.strip():
        return None
    response.check_returncode()
    return response.stdout.strip()


def save(state):
    state['updatedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    temp = STATE.with_suffix('.new')
    with temp.open('x') as output:
        json.dump(state, output, indent=2)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    os.replace(temp, STATE)


def append(path, text):
    with path.open('a') as output:
        output.write('\n' + text + '\n')


def update_records(result, passed):
    archive_relative = str(ARCHIVE.relative_to(RESEARCH))
    transaction_ids = {row['name']: row['transactionID'] for row in result['phases']}
    if passed:
        text = ('2026-10-23 续验计划ba127995…的三项Mach-O应用→撤销→重应用全部通过。'
                '三个阶段均完成独立只读审计，完整文件恢复为generation原件后再次恢复为首次应用状态。'
                '原VM12项文件最终完整内容复核及独立身份核对通过，342项冻结输入摘要保持，'
                '目标磁盘无挂载，两个受保护VM进程仍在。此前207项归档文件核验通过。'
                '本轮VM启动0次、辅助窗口0次。真实Preboot数据撤销、可信Guest来源桥接及运行效果仍待验，'
                'T32/T33整项accepted=false。')
        current = ('当前状态：续验计划ba127995…的三项Mach-O应用→撤销→重应用已全部通过独立只读验收。'
                   '三项完整文件的撤销状态与generation原件一致，重应用状态与首次应用一致；相关签名页核验通过。'
                   '原VM12项文件最终完整复核及独立身份核对通过，342项冻结输入保持。'
                   '本轮未启动VM或辅助窗口。真实Preboot数据撤销、可信Guest来源和运行效果仍未通过，整项accepted=false。')
    else:
        text = ('2026-10-23 续验计划ba127995…已结束，结果为失败；保留已通过阶段和原始失败记录，'
                '没有自动重试、回滚、VM启动或辅助窗口。错误：' + result.get('error', '未提供错误字段') +
                '。T32/T33整项accepted=false。')
        current = '当前状态：续验计划ba127995…已失败并停止。已通过阶段和失败证据保留；未自动重试。整项accepted=false。'
    report = RESEARCH / 'T32_T33_completion_20261023.md'
    lines = report.read_text().splitlines()
    indices = [i for i, line in enumerate(lines) if line.startswith('当前状态：')]
    if len(indices) != 1:
        raise ValueError('Current report status is ambiguous')
    lines[indices[0]] = current
    report.write_text('\n'.join(lines) + '\n')
    append(report, text + '\n事务：' + json.dumps(transaction_ids, ensure_ascii=False) +
           '\n归档清单：`' + archive_relative + '`。清单存在且摘要复核完成后，才计归档通过。')
    for filename in ('tasks.json', 'local_reconciliation.json'):
        path = RESEARCH / filename
        document = json.loads(path.read_text())
        found = []
        for task in document['tasks']:
            if task.get('id') not in ('T32', 'T33'):
                continue
            completion = task['completion_20261023']
            completion.update(state='continuation_offline_three_macho_passed' if passed else 'continuation_offline_failed',
                accepted=False, guestOriginQualified=False, runtimeValidated=False,
                continuationTransactions=transaction_ids, continuationOfflinePassed=passed,
                continuationFinalResult='resumed-offline-acceptance/result.json')
            if passed:
                completion.update(fileUndo='actual_three_macho_on_off_on_passed_preboot_actual_pending',
                    continuationReappliedPassed=True, continuationOriginalFinalFullReadbackPassed=True,
                    continuationFrozenInputsVerified=342,
                    remaining=['actual Preboot data file undo/reapplication acceptance',
                               'trusted guest producer/origin bridge', 'GUI/runtime and patch effect acceptance'])
            else:
                completion['continuationError'] = result.get('error')
            if archive_relative not in completion['evidence']:
                completion['evidence'].append(archive_relative)
            found.append(task['id'])
        if set(found) != {'T32', 'T33'}:
            raise ValueError('Missing completion records: ' + filename)
        path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')
    for path in (ROOT / 'TASKS.md', RESEARCH / 'progress.md', RESEARCH / 'local_reconciliation.md',
                 ROOT / 'research/0_binary_patch_comparison.md'):
        append(path, text)


def main():
    if sys.argv[1:] != ['--follow-existing-run', PLAN_SHA]:
        raise ValueError('Only the named existing run can be finalized')
    plan_path = WORK / 'resumed-file-acceptance-plan.json'
    if evidence.digest(plan_path) != PLAN_SHA:
        raise ValueError('Approved plan changed')
    approval = json.loads(evidence.read(WORK / 'resumed-file-acceptance-approval.json'))
    if approval != dict(approved=True, planSHA256=PLAN_SHA):
        raise ValueError('Approved scope missing')
    frozen = {str(path): evidence.digest(path) for path in (
        Path(__file__).resolve(), TOOLS / 'verify_t32_resumed_completion.py',
        TOOLS / 'archive_t32_resumed_acceptance.py', ROOT / 'scripts/cfw_guest_evidence.py')}
    if STATE.exists() or ARCHIVE.exists():
        raise ValueError('Preserve prior finalization/archive')
    native = process()
    if native is not None and ('execute_t32_resumed_file_acceptance.py --execute-approved-plan ' + PLAN_SHA) not in native:
        raise ValueError('Native process identity differs')
    if native is None and not RESULT.exists():
        raise ValueError('Existing native run and result are both absent')
    state = dict(state='waiting-existing-native-run', pid=os.getpid(), nativePID=NATIVE_PID,
                 nativeIdentity=native, planSHA256=PLAN_SHA, frozenFinalizationTools=frozen,
                 nativeRetries=0, VMStarts=0, securityWindows=0, accepted=False)
    save(state)
    print('Following existing native run; no native operation will be started', flush=True)
    try:
        deadline = time.monotonic() + 24 * 60 * 60
        while native is not None:
            if time.monotonic() >= deadline:
                raise ValueError('Finalization wait expired; existing native run was not stopped')
            current = process()
            if current is None:
                break
            if current != native:
                raise ValueError('Native PID identity changed; manual inspection required')
            time.sleep(2)
        if not RESULT.is_file():
            raise ValueError('Native run ended without a final result; manual inspection required')
        for path, digest in frozen.items():
            if evidence.digest(Path(path)) != digest:
                raise ValueError('Finalization tool changed: ' + path)
        result = json.loads(evidence.read(RESULT))
        if any(result.get(field) is not False for field in ('sourceVMWritten', 'VMStarted', 'securityWindowStarted')):
            raise ValueError('Unexpected native execution scope')
        passed = result.get('state') == 'resumed-offline-on-off-on-passed'
        state.update(state='verifying-native-result', nativeResultState=result.get('state'))
        save(state)
        if passed:
            subprocess.run([sys.executable, '-B', str(TOOLS / 'verify_t32_resumed_completion.py')],
                           cwd=ROOT, check=True)
        update_records(result, passed)
        subprocess.run([sys.executable, '-B', str(TOOLS / 'archive_t32_resumed_acceptance.py')],
                       cwd=ROOT, check=True)
        state.update(state='offline-acceptance-finalized' if passed else 'native-failure-archived',
                     offlineAcceptancePassed=passed, archive=str(ARCHIVE),
                     archiveSHA256=evidence.digest(ARCHIVE))
        save(state)
        print(json.dumps(state), flush=True)
        return 0 if passed else 1
    except Exception as error:
        state.update(state='finalization-stopped', error=str(error))
        save(state)
        print(json.dumps(state), flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

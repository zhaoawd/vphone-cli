#!/usr/bin/env python3
"""Archive the approved provider deployment and consumer observations separately."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-provider-fix-20261023'
DESTINATION = ROOT / 'research/upstream_integration_2026-10-15/evidence/T52-provider-fix-20261023/runtime'


def main():
    assert not DESTINATION.exists(), 'Preserve the existing evidence batch'
    inputs = []
    names = ['approval-record.json', 'deployment-plan.json', 'root-configuration.json',
             'execution-orchestration.json', 'execute-approved-deployment.py',
             'normal-stop-verification.json', 'normal-stop-requests.jsonl',
             'binding-before.json', 'binding-after.json', 'binding-command.log',
             'baseline-verified-root.json', 'root-install-receipt.json', 'root-verified-receipt.json',
             'root-deploy.log', 'root-deploy-auth.log', 'system-precheck.json',
             'system-maintenance-plan.json', 'system-maintenance-result.json',
             'system-postcheck.json', 'postcheck.json', 'system-root-window-start.log',
             'api-launch.json', 'api-launch.log', 'boot-readiness.jsonl', 'running-session.json',
             'formal-probe-build.log', 'formal-probe-sign.log', 'formal-probe-metadata.json',
             'verify-current-runtime.py', 'run-approved-consumption.py',
             'runtime-preflight.log', 'formal-probe-deployment.log',
             'location-consumer.log', 'camera-consumer.log', 'camera-live-logs.jsonl',
             'original-probe-restoration.log', 'runtime-final.log', 'consumption-result.json',
             'retained-disk-verification.json', 'final-source-state.json', 'final-source-state-requests.jsonl',
             'launcher-path-fix.json', 'launcher-path-fix.log', 'launch-approved-provider-session-path-fix.py',
             'boot-probe-stop.json', 'boot-probe-stop-requests.jsonl', 'consumption-execution.log',
             'consumption-execution-r2.log', 'runtime-preflight-ready.log', 'camera-live-summary.json']
    inputs += [WORK / name for name in names]
    for name in ['boot-window', 'formal-probe', 'runtime-preflight', 'runtime-preflight-ready', 'formal-probe-deployment',
                 'location-consumer', 'camera-consumer', 'original-probe-restoration', 'runtime-final']:
        inputs += [p for p in (WORK / name).rglob('*') if p.is_file()]
    sources = ['TASKS.md', 'research/0_binary_patch_comparison.md',
               'research/upstream_integration_2026-10-15/T52_provider_fix_20261023.md',
               'research/upstream_integration_2026-10-15/progress.md',
               'research/upstream_integration_2026-10-15/tasks.json',
               'research/upstream_integration_2026-10-15/local_reconciliation.json',
               'research/upstream_integration_2026-10-15/tools/archive_t52_provider_runtime.py']
    inputs += [ROOT / name for name in sources]
    for source in inputs:
        assert source.is_file() and not source.is_symlink(), source
    records = []; DESTINATION.mkdir(parents=True)
    for source in sorted(set(inputs)):
        relative = source.relative_to(ROOT); target = DESTINATION / 'files' / relative
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        assert hashlib.sha256(target.read_bytes()).hexdigest() == digest
        records.append(dict(origin=str(relative), path=str(target.relative_to(DESTINATION)),
                            bytes=source.stat().st_size, sha256=digest))
    candidate = json.loads((WORK / 'candidate.json').read_text())
    consumption = json.loads((WORK / 'consumption-result.json').read_text())
    manifest = dict(schemaVersion=1, scope='Approved single-library deployment and actual application consumption',
                    candidateVersion=candidate['version'], candidateArchiveSHA256=candidate['archiveSHA256'],
                    consumersPassed=consumption['consumersPassed'], accepted=False,
                    count=len(records), files=records)
    (DESTINATION / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for row in json.loads((DESTINATION / 'manifest.json').read_text())['files']:
        target = DESTINATION / row['path']; assert target.stat().st_size == row['bytes']
        assert hashlib.sha256(target.read_bytes()).hexdigest() == row['sha256']
    print(json.dumps(dict(count=len(records), allDigestsVerified=True, manifest=str(DESTINATION / 'manifest.json'))))


if __name__ == '__main__': main()

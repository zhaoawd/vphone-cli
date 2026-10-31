#!/usr/bin/env python3
"""Archive a fixed pre-restart observation without replacing prior evidence."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-consumer-fix-20261022'
DESTINATION = ROOT / 'research/upstream_integration_2026-10-15/evidence/T52-consumer-fix-20261022/runtime-before-camera-restart'


def main():
    assert not DESTINATION.exists(), 'Preserve the existing immutable batch'
    inputs = []
    names = ['amended-approval-record.json', 'amended-deployment-plan.json', 'system-maintenance-plan.json',
             'system-maintenance-result.json', 'system-postcheck.json', 'root-reports-handed-back.json',
             'boot-readonly-inputs.json', 'component-mappings-during-consumer.json',
             'camera-auth-preflight-current.json', 'camera-auth-request.json', 'camera-restart-plan.json',
             'camera-log-read-requests.jsonl', 'readonly-historical-log-attempt.json',
             'camera-consumer-r1.log', 'camera-consumer-r2-authorized.log', 'location-consumer-r1.log',
             'probe-camera-auth-build.log', 'probe-camera-auth-deployment.log',
             'publisher-transition-r1.log', 'tools-final-regression.log', 'tools-final-regression-outside.log']
    directories = ['boot-window', 'location-consumer-r1', 'camera-consumer-r1', 'camera-consumer-r2-authorized',
                   'publisher-transition-r1', 'probe-deployment-r1', 'probe-camera-auth-deployment',
                   'probe-dispatch-deployment', 'dispatch-readonly-r1', 'dispatch-analysis-r1',
                   'enumeration-live-r1', 'enumeration-live-r2', 'runtime-verification-r1',
                   'probe-camera-auth', 'probe-dispatch-readonly']
    inputs += [WORK / name for name in names]
    for directory in directories:
        inputs += [p for p in (WORK / directory).rglob('*') if p.is_file()]
    source_names = ['TASKS.md', 'research/0_binary_patch_comparison.md',
                    'research/probes/t52_application_probe.m', 'research/probes/t52_capture_source_diagnostic.inc',
                    'research/probes/build_t52_application_probe.zsh',
                    'research/upstream_integration_2026-10-15/T52_consumer_fix_20261022.md',
                    'research/upstream_integration_2026-10-15/progress.md',
                    'research/upstream_integration_2026-10-15/tasks.json',
                    'research/upstream_integration_2026-10-15/local_reconciliation.json']
    source_names += ['research/upstream_integration_2026-10-15/tools/' + name for name in [
        'capture_t52_camera_enumeration.py', 'capture_t52_camera_restart.py',
        'run_t52_capture_source_diagnostic.py', 'disassemble_t52_capture_source.py',
        'test_t52_capture_source_cleanup.py', 'test_t52_camera_restart.py',
        'archive_t52_consumer_runtime.py']]
    inputs += [ROOT / name for name in source_names]
    records = []
    DESTINATION.mkdir()
    for source in sorted(set(inputs)):
        assert source.is_file() and not source.is_symlink(), source
        relative = source.relative_to(ROOT)
        target = DESTINATION / 'files' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        assert hashlib.sha256(target.read_bytes()).hexdigest() == digest
        records.append(dict(origin=str(relative), path=str(target.relative_to(DESTINATION)),
                            bytes=source.stat().st_size, sha256=digest))
    manifest = dict(schemaVersion=1, scope='Runtime before separately approved camera-daemon restart',
                    accepted=False, locationPassed=True, cameraReceiptPassed=True, QRConsumerPassed=False,
                    cameraRestartExecuted=False, count=len(records), files=records)
    (DESTINATION / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    # Independently read every archived item again through the final manifest.
    saved = json.loads((DESTINATION / 'manifest.json').read_text())
    for row in saved['files']:
        target = DESTINATION / row['path']
        assert target.stat().st_size == row['bytes']
        assert hashlib.sha256(target.read_bytes()).hexdigest() == row['sha256']
    print(json.dumps(dict(count=len(records), allDigestsVerified=True, manifest=str(DESTINATION / 'manifest.json'))))


if __name__ == '__main__': main()

#!/usr/bin/env python3
"""Freeze diagnostics and the prepared single-library plan; never replace prior batches."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-provider-fix-20261023'
PREVIOUS = ROOT / '.build/t52-consumer-fix-20261022'
DESTINATION = ROOT / 'research/upstream_integration_2026-10-15/evidence/T52-provider-fix-20261023/prepared'


def main():
    assert not DESTINATION.exists(), 'Preserve prior evidence'
    inputs = []
    for name in ['candidate.json', 'candidate-build.log', 'candidate-build-final.log', 'library-build.log',
                 'provider-tests.log', 'transaction-tests.log', 'transaction-tests-final.log',
                 'python-full.log', 'python-full-outside.log', 'tools-regression.log',
                 'tools-regression-final.log', 'tools-regression-sealed.log', 'amfid-cleanup-tests.log',
                 'camera-after-restart.log', 'camera-after-restart-r2.log',
                 'deployment-plan.json', 'root-configuration.json', 'install-provider-candidate.zsh',
                 'launch-approved-provider-session.py']:
        inputs.append(WORK / name)
    for name in ['camera-after-restart', 'camera-after-restart-r2', 'predeployment-state', 'boot-window']:
        inputs += [p for p in (WORK / name).rglob('*') if p.is_file()]
    for name in ['camera-restart-approval.json', 'camera-restart-plan.json', 'provider-nil-red.log', 'provider-nil-green.log']:
        inputs.append(PREVIOUS / name)
    for name in ['camera-restart-r1', 'camera-restart-r2', 'provider-types-readonly-r1',
                 'provider-initialization-readonly-r1', 'provider-initialization-analysis-r1',
                 'provider-query-r1', 'provider-callees-readonly-r1', 'provider-fallback-test-r1',
                 'probe-provider-types-deployment', 'probe-provider-initialization-deployment',
                 'probe-provider-query-deployment', 'probe-provider-callees-deployment',
                 'probe-provider-fallback-test-deployment']:
        inputs += [p for p in (PREVIOUS / name).rglob('*') if p.is_file()]
    sources = ['TASKS.md', 'dependencies/guest-components-pins.json', 'research/0_binary_patch_comparison.md',
               'sources/VPhoneGuestComponents/VCamCaptured/VCamSourceProvider.inc',
               'tests/test_guest_camera_source_provider.py', 'tests/fixtures/guest_camera_source_provider.m',
               'tests/test_t52_provider_maintenance.py', 'research/probes/t52_application_probe.m',
               'research/probes/t52_capture_source_diagnostic.inc', 'research/probes/build_t52_application_probe.zsh']
    sources += ['research/upstream_integration_2026-10-15/' + name for name in [
        'T52_provider_fix_20261023.md', 'T52_consumer_fix_20261022.md', 'progress.md', 'tasks.json', 'local_reconciliation.json']]
    sources += ['research/upstream_integration_2026-10-15/tools/' + name for name in [
        'build_t52_provider_candidate.py', 't52_provider_maintenance.py', 'deploy_t52_provider_root.py',
        't52_amfid_cleanup.py', 'test_t52_amfid_cleanup.py', 't52_helper_supervisor.py',
        'capture_t52_camera_restart.py', 'run_t52_capture_source_diagnostic.py',
        'disassemble_t52_capture_source.py', 'run_t52_camera_consumer.py', 'test_t52_camera_consumer.py',
        'archive_t52_provider_prepared.py']]
    inputs += [ROOT / name for name in sources]
    records = []; DESTINATION.mkdir(parents=True)
    for source in sorted(set(inputs)):
        assert source.is_file() and not source.is_symlink(), source
        relative = source.relative_to(ROOT); target = DESTINATION / 'files' / relative
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        assert hashlib.sha256(target.read_bytes()).hexdigest() == digest
        records.append(dict(origin=str(relative), path=str(target.relative_to(DESTINATION)), bytes=source.stat().st_size, sha256=digest))
    candidate = json.loads((WORK / 'candidate.json').read_text())
    manifest = dict(schemaVersion=1, scope='Camera restart diagnosis and prepared nil-provider candidate',
                    candidateVersion=candidate['version'], candidateArchiveSHA256=candidate['archiveSHA256'],
                    candidateInstalled=False, newWindowStarted=False, accepted=False, count=len(records), files=records)
    (DESTINATION / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for row in json.loads((DESTINATION / 'manifest.json').read_text())['files']:
        target = DESTINATION / row['path']; assert target.stat().st_size == row['bytes']
        assert hashlib.sha256(target.read_bytes()).hexdigest() == row['sha256']
    print(json.dumps(dict(count=len(records), allDigestsVerified=True, manifest=str(DESTINATION / 'manifest.json'))))


if __name__ == '__main__': main()

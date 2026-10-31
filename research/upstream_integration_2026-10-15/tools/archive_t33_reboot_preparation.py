"""Archive reviewed sources and verification; grant no real recovery authority."""
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / '.build/t32-t33-completion-20261023'
RESEARCH = ROOT / 'research/upstream_integration_2026-10-15'
OUT = RESEARCH / 'evidence/T32-T33-completion-20261023/reboot-recovery-preparation-20261026'


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    if OUT.exists(): raise ValueError('Preserve existing preparation archive')
    candidate_path = BASE / 'candidate-exp-reboot-recovery-20261026.json'
    candidate = json.loads(candidate_path.read_bytes()); bundle = Path(candidate['bundle'])
    if (digest(Path(candidate['archive'])) != candidate['archiveSHA256']
            or digest(bundle / 'Contents/MacOS/vphone-cli') != candidate['cliSHA256']
            or digest(bundle / 'Contents/MacOS/vphone-vm') != candidate['vmSHA256']):
        raise ValueError('Prepared candidate differs')
    paths = {candidate_path, Path(__file__), RESEARCH / 'T32_T33_reboot_recovery_20261026.md',
        RESEARCH / 'T32_T33_reboot_recovery_execution_review_20261026.md'}
    paths |= set((RESEARCH / 'tools').glob('*t33*reboot*.py'))
    paths |= {RESEARCH / 'tools' / name for name in ('run_t33_recovered_undo.py', 'test_t33_recovered_undo_worker.py')}
    paths |= {ROOT / name for name in (
        'scripts/cfw_reboot_identity.py', 'scripts/cfw_disk_txn.py', 'scripts/cfw_guest_evidence.py',
        'scripts/check_bundle.py', 'scripts/patchers/guest_recovery.py', 'scripts/patchers/guest_undo.py',
        'sources/FirmwarePatcher/Pipeline/FirmwareRebootIdentity.swift',
        'sources/FirmwarePatcher/Pipeline/FirmwareGuestDiskIdentity.swift',
        'tests/test_cfw_reboot_identity.py', 'tests/test_guest_reboot_recovery.py',
        'tests/test_cfw_host_isolation.py', 'tests/cfw_reboot_mixed_identity_fixture.py',
        'tests/FirmwarePatcherTests/FirmwareRebootIdentityTests.swift',
        'tests/VPhoneCLITests/CFWRebootIdentityBridgeTests.swift',
        'tests/VPhoneCLITests/CFWOriginIdentityBridgeTests.swift')}
    paths |= set(BASE.glob('reboot-*-20261026.log'))
    paths |= {bundle / 'Contents/Resources' / name for name in
              ('build-dependencies.json', 't32-producer-provenance.json')}
    paths |= {BASE / name for name in ('probe_t33_reboot_identity.before-binary-isolation-20261026.py',
        'probe_t33_reboot_identity.before-final-binary-20261026.py')}
    # An active readonly probe may later create its output; archive it separately
    # when complete rather than freezing a growing log here.
    paths.discard(BASE / 'reboot-real-identity-preflight-20261026.log')
    OUT.mkdir()
    rows = []
    for source in sorted(paths):
        if source.suffix == '.py': ast.parse(source.read_text())
        relative = source.relative_to(ROOT)
        destination = OUT / relative; destination.parent.mkdir(parents=True, exist_ok=True)
        before = digest(source); shutil.copyfile(source, destination)
        if digest(source) != before or digest(destination) != before:
            raise ValueError('Preparation archive differs: ' + str(source))
        rows.append(dict(path=str(relative), source=str(source), sha256=before, bytes=source.stat().st_size))
    volume = os.statvfs(ROOT)
    status = dict(candidate=candidate['version'], candidateInstalled=False, publicationApproved=False,
        actualRecoveryExecuted=False, VMStarts=0, securityWindows=0, accepted=False,
        readonlyAuthenticationPID=33141, readonlyAuthenticationSession=30699,
        readonlyReplayCompleted=(BASE / 'reboot-real-identity-preflight-20261026/result.json').exists(),
        newPlanPrepared=(BASE / 'exp-reboot-recovery-acceptance-20261026/offline-plan.json').exists(),
        availableBytes=volume.f_bavail * volume.f_frsize,
        validation=dict(pythonTests=1160, skipped=4, seconds=300.577, exitCode=0,
            newWorkerAndExecutorTests=12, newWorkerAndExecutorSeconds=2.0,
            mixedSwiftHistoryFixturePassed=True, guestAssetsUnchanged=True),
        limitation='APFS recovery and root registration on the real VM remain unexecuted; a new specific approval is required after actual readonly preflight')
    path = OUT / 'status.json'; path.write_text(json.dumps(status, indent=2) + '\n')
    rows.append(dict(path='status.json', sha256=digest(path), bytes=path.stat().st_size))
    manifest = OUT / 'manifest.json'
    manifest.write_text(json.dumps(dict(schemaVersion=1, files=rows, accepted=False), indent=2) + '\n')
    for row in rows:
        if digest(OUT / row['path']) != row['sha256']: raise ValueError('Final archive readback differs')
    print(json.dumps(dict(files=len(rows), manifestSHA256=digest(manifest), candidate=candidate['version'],
        actualRecoveryExecuted=False, accepted=False)))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Archive the approved diagnostic deployment without changing earlier evidence."""
import hashlib
import json
from pathlib import Path
import shutil
import time

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-camera-diagnostics-20261022'
DEST = ROOT / 'research/upstream_integration_2026-10-15/evidence/T52-camera-diagnostic-20261022'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert json.loads((WORK / 'authorization.json').read_text())['approved'] is True
    assert json.loads((WORK / 'postcheck.json').read_text())['classification'] == 'already_current'
    stopped = json.loads((WORK / 'boot-window/stop-verification.json').read_text())
    assert stopped['attachments'] == 1 and stopped['within900Seconds'] is True
    final = json.loads((WORK / 'final-observation.json').read_text())
    assert final['location']['state'] == 'off' and final['camera']['streaming'] is False
    assert final['probeStopped'] and final['helperAbsent'] and final['retainedOldDiskIdentityVerified']
    selected = []
    for path in WORK.iterdir():
        if path.is_file() and path.suffix in ('.json', '.jsonl', '.log', '.jpg', '.zsh'):
            selected.append((path, 'diagnostic/' + path.name))
        if path.is_dir() and (path.name == 'boot-window' or path.name.startswith(
                ('initialization-capture-', 'followup-', 'camera-consumer-', 'location-consumer-', 'location-api-bridge-'))):
            for child in path.rglob('*'):
                if child.is_file() and child.suffix in ('.json', '.jsonl', '.log', '.py', '.zsh'):
                    selected.append((child, 'diagnostic/' + str(child.relative_to(WORK))))
    history = ROOT / '.build/t51rt/lib/t52-v2/.environment-history/environment-728bf0d4-fa9d-4c12-b5f9-413c93cccb11'
    for name in ('transaction.json', 'environment-update.json'):
        selected.append((history / name, 'retained-disk-transaction/' + name))
    tools = Path(__file__).parent
    for name in ('capture_t52_camera_init.py', 'diagnose_t52_location_bridge.py',
                 'launch_t52_diagnostic_session.py', 'test_t52_diagnostic_readiness.py',
                 't52_helper_supervisor.py', 'test_t52_helper_supervisor.py',
                 'archive_t52_camera_diagnostic.py'):
        selected.append((tools / name, 'source/tools/' + name))
    rows = []
    for source, relative in sorted(selected, key=lambda pair: pair[1]):
        assert source.stat().st_size <= 2 << 20, 'Unexpected large evidence: ' + str(source)
        target = DEST / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        digest = sha(source)
        if target.exists():
            assert sha(target) == digest, 'Preserve previously archived evidence: ' + relative
        else:
            shutil.copyfile(source, target)
        assert sha(target) == digest
        rows.append(dict(path=relative, source=str(source.relative_to(ROOT)), bytes=source.stat().st_size, sha256=digest))
    previous = ROOT / 'research/upstream_integration_2026-10-15/evidence/T52-signature-camera-20261022/manifest.json'
    result = dict(schemaVersion=1, observedAt=time.time(), accepted=False,
                  deployedBundle='2.6.2-local.56be1ce20ded', diagnosticApproval='approved',
                  actualLocationAccepted=False, actualQRAccepted=False,
                  helperElapsedSeconds=stopped['elapsedSeconds'], helperAttachments=1,
                  vmInstanceID=final['runtime']['instanceID'],
                  previousEvidence=dict(path=str(previous.relative_to(ROOT)), sha256=sha(previous)),
                  archived=rows)
    manifest = DEST / 'manifest.json'
    assert not manifest.exists(), 'Use a new batch instead of replacing a manifest'
    manifest.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(archived=len(rows), accepted=False, manifest=str(manifest.relative_to(ROOT)))))


if __name__ == '__main__': main()

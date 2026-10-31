#!/usr/bin/env python3
"""Archive bounded T52 camera/signature records; excludes disks, payloads and keys."""
import hashlib
import json
from pathlib import Path
import shutil
import time

ROOT = Path(__file__).resolve().parents[3]
DEST = ROOT / 'research/upstream_integration_2026-10-15/evidence/T52-signature-camera-20261022'
WORK = ROOT / '.build/t52-camera-interface-20261022'
DIAGNOSTIC = ROOT / '.build/t52-camera-diagnostics-20261022'
APP = ROOT / '.build/t52-app-acceptance-20261022'


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while block := f.read(1 << 20): h.update(block)
    return h.hexdigest()


def main():
    DEST.mkdir(exist_ok=True)
    selected = []
    for base, label in [(WORK, 'interface'), (DIAGNOSTIC, 'diagnostic')]:
        for p in base.iterdir():
            if p.is_file() and p.suffix in ('.json', '.log', '.jpg'):
                selected.append((p, label + '/' + p.name))
            if p.is_dir() and (p.name == 'boot-window' or p.name.startswith(('location-consumer-', 'camera-consumer-', 'publisher-deployment-', 'probe-', 'injection-diagnosis-'))):
                for child in p.rglob('*'):
                    if child.is_file() and child.suffix in ('.json', '.jsonl', '.log', '.plist', '.jpg'):
                        selected.append((child, label + '/' + str(child.relative_to(base))))
    for name in ['signature-cms-r1', 'signature-diagnosis-r2']:
        for p in (APP / name).rglob('*'):
            if p.is_file() and p.suffix in ('.json', '.jsonl', '.log', '.plist'):
                selected.append((p, 'signature/' + str(p.relative_to(APP))))
    # Save exact source snapshots separately from each candidate's immutable
    # source digests; the current worktree may contain later diagnostic edits.
    for relative in ['research/probes/t52_application_probe.m', 'research/probes/build_t52_application_probe.zsh',
                     'research/probes/generate_t52_camera_frames.m', 'tests/test_t52_environment_maintenance.py',
                     'tests/test_guest_vcam_bridge.py', 'tests/fixtures/guest_vcam_bridge.m',
                     'research/upstream_integration_2026-10-15/tools/t52_environment_maintenance.py',
                     'research/upstream_integration_2026-10-15/tools/t52_helper_supervisor.py',
                     'research/upstream_integration_2026-10-15/tools/run_t52_camera_consumer.py',
                     'research/upstream_integration_2026-10-15/tools/run_t52_location_consumer.py']:
        selected.append((ROOT / relative, 'source/' + relative))
    archived, references = [], []
    for source, relative in sorted(selected, key=lambda pair: pair[1]):
        row = dict(path=relative, source=str(source.relative_to(ROOT)), bytes=source.stat().st_size, sha256=sha(source))
        if source.stat().st_size > 2 << 20:
            references.append(row); continue
        target = DEST / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if sha(target) != row['sha256']:
                raise RuntimeError('Preserve previous archived evidence: ' + relative)
        else:
            shutil.copyfile(source, target)
        assert sha(target) == row['sha256']
        archived.append(row)
    result = dict(schemaVersion=1, observedAt=time.time(), accepted=False,
                  deployedBundle='2.6.2-local.93805a71796d', diagnosticCandidate='2.6.2-local.56be1ce20ded',
                  diagnosticApproval='pending', signatureABAPassed=True, actualLocationAccepted=False,
                  actualQRAccepted=False, archived=archived, retainedOriginalReferences=references)
    (DEST / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(archived=len(archived), retainedLargeReferences=len(references), accepted=False)))


if __name__ == '__main__': main()

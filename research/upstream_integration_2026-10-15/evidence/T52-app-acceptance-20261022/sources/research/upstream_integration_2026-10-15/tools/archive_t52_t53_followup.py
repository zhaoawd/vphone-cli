#!/usr/bin/env python3
"""Archive follow-up source and metadata; exclude VM images and executables."""
import gzip
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RESEARCH = ROOT / 'research/upstream_integration_2026-10-15'


def archive(name, directories, sources, status):
    out = RESEARCH / 'evidence' / name
    out.mkdir(parents=True, exist_ok=True)

    def copy(source, relative):
        data = source.read_bytes()
        target = out / relative
        if source.suffix == '.log':
            data = gzip.compress(data, mtime=0)
            target = target.with_name(target.name + '.gz')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    for label, directory in directories:
        for path in sorted(directory.rglob('*')):
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(directory)
            allowed = path.suffix in ('.json', '.jsonl', '.log', '.txt', '.png', '.jpg', '.jpeg', '.plist', '.py')
            if 'upstream' in relative.parts:
                allowed = True
            if allowed and 'products' not in relative.parts and '.app' not in str(relative):
                copy(path, Path(label) / relative)
    for relative in sources:
        copy(ROOT / relative, Path('sources') / relative)
    entries = []
    for path in sorted(out.rglob('*')):
        if path.is_file() and path != out / 'manifest.json':
            entries.append(dict(path=str(path.relative_to(out)), bytes=path.stat().st_size,
                                sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    (out / 'manifest.json').write_text(json.dumps(dict(schemaVersion=1, **status, files=entries), indent=2) + '\n')
    print(json.dumps(dict(evidence=name, files=len(entries), bytes=sum(f['bytes'] for f in entries))))


if __name__ == '__main__':
    rp = 'research/upstream_integration_2026-10-15/'
    archive('T53-developer-20261022', [('r1', ROOT / '.build/t53-developer-20261022'),
                                     ('r2', ROOT / '.build/t53-developer-20261022-r2')],
            [rp + 'T53_developer_compatibility_20261022.md',
             rp + 'tools/prepare_t53_developer_candidate.py', 'tests/test_undo_provenance.py'],
            dict(upstreamTarget='2a0d3aca9fb79344d939365cc337b915ae9f2f97',
                 scope='Fixed-source audit and isolated candidates; no product integration or developer-tool runtime acceptance',
                 accepted=False, guestInstalled=False, runtimeValidated=False))
    archive('T52-app-acceptance-20261022', [('preparation', ROOT / '.build/t52-app-acceptance-20261022')],
            [rp + 'T52_application_acceptance_20261022.md', rp + 'tools/verify_t52_default_shutdown.py',
             rp + 'tools/accept_t52_default_shutdown_ui.cua.mjs',
             rp + 'tools/verify_t52_application_observation.py', rp + 'tools/test_t52_application_observation.py',
             rp + 'tools/reproduce_t52_probe_launch.py',
             rp + 'tools/install_t52_probe_container.py', rp + 'tools/verify_t52_camera_readiness.py',
             rp + 'tools/archive_t52_t53_followup.py',
             'scripts/vphoned/vphoned_vcam.h', 'scripts/vphoned/vphoned_vcam.m',
             'sources/VPhoneGuestComponents/VCamCaptured/VCamFrameProtocol.h',
             'research/probes/t52_application_probe.m', 'research/probes/build_t52_application_probe.zsh',
             'research/probes/camera_qr_probe.entitlements.plist'],
            dict(scope='Actual new-host GUI start/stop passed; native container probe installed, launch and camera readiness failed; consumer behavior unverified',
                 accepted=False, syntheticObservationTestsAreRuntimeEvidence=False))

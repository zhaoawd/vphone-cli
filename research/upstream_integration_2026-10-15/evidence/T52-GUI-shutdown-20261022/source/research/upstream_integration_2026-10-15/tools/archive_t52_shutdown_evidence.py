#!/usr/bin/env python3
"""Archive the shutdown repair separately from prior runtime acceptance."""
import gzip
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-real-20261021'
out = root / 'research/upstream_integration_2026-10-15/evidence/T52-GUI-shutdown-20261022'
out.mkdir(parents=True, exist_ok=True)


def copy(source, relative):
    target = out / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    data = source.read_bytes()
    if source.suffix == '.log':
        target = target.with_name(target.name + '.gz')
        data = gzip.compress(data, mtime=0)
    target.write_bytes(data)


for path in sorted(work.glob('gui-shutdown-*.log')):
    copy(path, Path('runtime') / path.name)
for directory in (work / 'gui-shutdown-fix', work / 'gui-shutdown-fix/boot-window'):
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.suffix in ('.json', '.py', '.zsh', '.log', '.jsonl'):
            copy(path, Path('runtime/gui-shutdown-fix') / path.relative_to(work / 'gui-shutdown-fix'))
ui = work / 'gui-shutdown-fix/ui'
if ui.exists():
    for path in sorted(ui.iterdir()):
        if path.is_file() and path.suffix in ('.txt', '.png', '.json'):
            copy(path, Path('runtime/gui-shutdown-fix/ui') / path.name)
for name in ('sources/vphone-cli/VPhoneAppDelegate.swift', 'sources/VPhoneAPIKit/VPhoneAPIGuestShutdown.swift',
             'sources/VPhoneCore/VPhoneShutdownPolicy.swift', 'tests/VPhoneCLITests/GuestShutdownTests.swift',
             'tests/VPhoneAPIKitTests/APIGuestShutdownTests.swift',
             'research/upstream_integration_2026-10-15/tools/build_t52_shutdown_candidate.py',
             'research/upstream_integration_2026-10-15/tools/verify_t52_default_shutdown.py',
             'research/upstream_integration_2026-10-15/tools/accept_t52_default_shutdown_ui.cua.mjs',
             'research/upstream_integration_2026-10-15/tools/apply_t52_host_rebind_ui.cua.mjs',
             'research/upstream_integration_2026-10-15/tools/t52_serial_evidence.py',
             'research/upstream_integration_2026-10-15/tools/test_t52_serial_evidence.py',
             'research/upstream_integration_2026-10-15/tools/verify_t52_shutdown_cleanup.py',
             'research/upstream_integration_2026-10-15/tools/archive_t52_shutdown_evidence.py'):
    copy(root / name, Path('source') / name)
report = root / 'research/upstream_integration_2026-10-15/T52_default_GUI_shutdown_20261022.md'
copy(report, Path(report.name))
entries = []
for path in sorted(out.rglob('*')):
    if path.is_file() and path != out / 'manifest.json':
        entries.append(dict(path=str(path.relative_to(out)), bytes=path.stat().st_size,
                            sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
(out / 'manifest.json').write_text(json.dumps(dict(schemaVersion=1, accepted=False,
    defaultGUIShutdownAcceptancePassed=True,
    scope='Default GUI shutdown source repair, signed candidate and real GUI launch/normal stop; full T52 acceptance remains incomplete',
    files=entries), indent=2) + '\n')
print(json.dumps(dict(files=len(entries), manifest=str(out / 'manifest.json'))))

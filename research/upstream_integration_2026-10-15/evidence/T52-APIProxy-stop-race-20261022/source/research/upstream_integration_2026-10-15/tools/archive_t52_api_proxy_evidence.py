#!/usr/bin/env python3
"""Archive local APIProxy stop-race experiments without touching VM artifacts."""
import gzip
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-api-proxy-20261022'
out = root / 'research/upstream_integration_2026-10-15/evidence/T52-APIProxy-stop-race-20261022'
out.mkdir(parents=True, exist_ok=True)


def copy(source, relative):
    target = out / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    data = source.read_bytes()
    if source.suffix == '.log':
        target = target.with_name(target.name + '.gz')
        data = gzip.compress(data, mtime=0)
    target.write_bytes(data)


for source in sorted(work.iterdir()):
    if source.is_file() and source.suffix in ('.log', '.json', '.swift', '.patch'):
        copy(source, Path('experiments') / source.name)
for name in ('sources/VPhoneAPIKit/VPhoneAPIProxy.swift', 'tests/VPhoneAPIKitTests/APIProxyTests.swift',
             'research/upstream_integration_2026-10-15/tools/archive_t52_api_proxy_evidence.py'):
    copy(root / name, Path('source') / name)
report = root / 'research/upstream_integration_2026-10-15/T52_APIProxy_stop_race_20261022.md'
copy(report, Path(report.name))
entries = []
for path in sorted(out.rglob('*')):
    if path.is_file() and path != out / 'manifest.json':
        entries.append(dict(path=str(path.relative_to(out)), bytes=path.stat().st_size,
                            sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
(out / 'manifest.json').write_text(json.dumps(dict(schemaVersion=1,
    scope='APIProxy stop/admission race diagnosed and repaired; original mixed tests pass without separation',
    sourceRepairVerified=True, mixedTestsPerRun=110, mixedRuns=3, accepted=False, committed=False,
    installedBundleChanged=False, VMStarted=False, files=entries), indent=2) + '\n')
print(json.dumps(dict(files=len(entries), manifest=str(out / 'manifest.json'))))

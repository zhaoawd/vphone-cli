#!/usr/bin/env python3
"""Archive deployment metadata and logs, excluding programs and VM images."""
import gzip
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-api-proxy-deploy-20261022'
out = root / 'research/upstream_integration_2026-10-15/evidence/T52-APIProxy-deployment-20261022'
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
    if source.is_file() and source.suffix in ('.log', '.json', '.zsh'):
        copy(source, Path('deployment') / source.name)
for name in ('build_t52_api_proxy_deployment.py', 'finish_t52_api_proxy_deployment.py', 'archive_t52_api_proxy_deployment.py'):
    source = root / 'research/upstream_integration_2026-10-15/tools' / name
    copy(source, Path('tools') / name)
report = root / 'research/upstream_integration_2026-10-15/T52_APIProxy_deployment_20261022.md'
copy(report, Path(report.name))
entries = []
for path in sorted(out.rglob('*')):
    if path.is_file() and path != out / 'manifest.json':
        entries.append(dict(path=str(path.relative_to(out)), bytes=path.stat().st_size,
                            sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
result = work / 'deployment-result.json'
(out / 'manifest.json').write_text(json.dumps(dict(schemaVersion=1,
    scope='Committed APIProxy repair and verified local Core Bundle installation and stopped t52-v2 host binding; no VM boot',
    sourceCommit=json.loads((work / 'commit.json').read_text())['commit'],
    deployed=result.exists(), accepted=False, VMStarted=False, AMFIChanged=False, files=entries), indent=2) + '\n')
print(json.dumps(dict(files=len(entries), deployed=result.exists(), manifest=str(out / 'manifest.json'))))

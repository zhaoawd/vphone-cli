#!/usr/bin/env python3
"""Read back the four preserved T32/T33 completion evidence batches."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t32-t33-completion-20261023'
BASE = ROOT / 'research/upstream_integration_2026-10-15/evidence'
BATCHES = ['T32-T33-completion-20261023/prepared',
           'T32-T33-completion-20261023/offline-refusal',
           'T32-T33-completion-20261023/fresh-offline',
           'T32-T33-completion-20261023/external-mount-fix-prepared']


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()


def main():
    batches = {}
    for name in BATCHES:
        folder = BASE / name
        manifest = json.loads((folder / 'manifest.json').read_text())
        rows = manifest['files']
        if isinstance(rows, dict):
            rows = [dict(path=path, **row) for path, row in rows.items()]
        for row in rows:
            path = folder / row['path']
            path.resolve(strict=True).relative_to(folder.resolve(strict=True))
            if (path.is_symlink() or path.stat().st_size != row['bytes']
                    or digest(path) != row['sha256']):
                raise ValueError('Archived evidence differs: ' + str(path))
        batches[name] = dict(files=len(rows), manifestSHA256=digest(folder / 'manifest.json'), allDigestsVerified=True)
    result = dict(batches=batches, allDigestsVerified=True, count=sum(row['files'] for row in batches.values()))
    with (WORK / 'resumed-prior-archives-preserved.json').open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()

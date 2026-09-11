#!/usr/bin/env python3
"""Prepare isolated C4 fixtures from verified local C3 inputs; no network or mounts."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import c3_full_pipeline_acceptance as common

ROOT = Path(__file__).resolve().parents[1]
C3 = ROOT / 'research/artifacts/c3-full-pipeline-2026-09-10'
LESS = ROOT / 'research/artifacts/c3-less-pipeline-2026-09-10'


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            result.update(data)
    return result.hexdigest()


def clone(source, target):
    if source.is_symlink() or target.exists() or target.is_symlink():
        raise ValueError('Refusing symlink or existing output')
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/bin/cp', '-c', str(source), str(target)], check=True)


def nonless():
    out = ROOT / 'research/artifacts/c4-nonless-2026-09-11'
    out.mkdir(exist_ok=False)
    for source in (C3 / 'stock').rglob('*'):
        if source.is_file():
            clone(source, out / 'stock' / source.relative_to(C3 / 'stock'))
    common.OUTPUT = out
    common.stage('acceptance')


def less():
    out = ROOT / 'research/artifacts/c4-less-2026-09-11'
    out.mkdir(exist_ok=False)
    metadata = json.loads((LESS / 'staging.json').read_text())
    sources = []
    for record in metadata['files']:
        relative = Path(record['output'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid recorded relative path')
        candidates = [C3 / 'stock' / record['source'] / record['member'], LESS / relative]
        if record.get('reused_from'):
            candidates.append(ROOT / record['reused_from'])
        source = next((p for p in candidates if p.is_file() and not p.is_symlink()
                       and p.stat().st_size == record['bytes'] and sha(p) == record['local_sha256']), None)
        if source is None:
            raise ValueError(f"No unchanged local input: {record['source']}:{record['member']}")
        clone(source, out / relative)
        if sha(out / relative) != record['local_sha256']:
            raise ValueError('Cloned input digest differs')
        sources.append({'source': str(source.relative_to(ROOT)), 'output': str(relative), 'sha256': record['local_sha256']})
    restore = out / 'vm/iPhone17,3_26.1_23B85_Restore'
    for name in ('BuildManifest.plist', 'Restore.plist'):
        clone(LESS / 'hybrid' / name, restore / name)
    clone(LESS / 'original/iphone/BuildManifest.plist', restore / 'iPhone-BuildManifest.plist')
    booter = C3 / 'stock/AVPBooter.vresearch1.bin'
    if sha(booter) != metadata['booter']['sha256']:
        raise ValueError('AVPBooter digest differs')
    clone(booter, out / 'vm' / booter.name)
    if sha(restore / 'BuildManifest.plist') != metadata['hybrid_manifest_sha256']:
        raise ValueError('Hybrid manifest differs')
    (out / 'sources.json').write_text(json.dumps(sources, indent=2) + '\n')
    print(out / 'vm', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('variant', choices=['nonless', 'less'])
    args = parser.parse_args()
    (nonless if args.variant == 'nonless' else less)()

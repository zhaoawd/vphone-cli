#!/usr/bin/env python3
"""Read final guest effects plus live Bundle inputs; never grant producer origin.

The Swift installed reader owns image/mount qualification and the live Store
callback. This result remains inspection data until C2 supplies actual producer
capture and the CFW journal's supported disk-identity transition.
"""
import json
from pathlib import Path
import sys
from patchers import component_effects as effects
from patchers import plan_gate as gate


def bundle_path(path, resources):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts or resources not in path.parents:
        raise ValueError('unqualified Bundle input source')
    current = path
    while current != resources:
        if current.is_symlink(): raise ValueError('linked Bundle input source')
        current = current.parent
    return path


def verify_sources(rows, resources):
    """A prior actual row may explain a moved/changed source; new sources must
    still equal a member of the live verified Bundle, including metadata/tree.
    The existing A2 verifier separately checks each full transport composition.
    """
    resources = Path(resources)
    if resources.is_symlink() or not resources.is_dir(): raise ValueError('invalid Bundle resources root')
    produced = {}
    for row in rows:
        proof = row.get('effect')
        if not isinstance(proof, dict): raise ValueError('legacy row lacks effect proof')
        if proof.get('operation') == 'copy':
            source = proof.get('sourcePath')
            if source in produced:
                if produced[source] != proof.get('source'): raise ValueError('producer input state differs')
            else:
                if not isinstance(source, str): raise ValueError('copy source association missing')
                path = bundle_path(source, resources)
                if effects.state(path) != proof.get('source'): raise ValueError('live Bundle source differs from observed source')
        archive = proof.get('sourceArchive')
        if archive is not None:
            source = archive.get('archivePath')
            if source not in produced:
                path = bundle_path(source, resources)
                if effects.digest(path) != archive.get('archiveSHA256'): raise ValueError('live Bundle archive differs')
        produced[row['path']] = proof.get('after')


def verify(plan, evidence, blobs, roots, resources):
    raw = gate.strict_bytes(evidence)
    rows = [json.loads(line) for line in raw.splitlines() if line]
    if not rows: raise ValueError('missing installed operation evidence')
    verify_sources(rows, resources)
    outputs = effects.verify_rows(plan, rows, roots, blobs)
    verify_sources(rows, resources)
    if gate.strict_bytes(evidence) != raw: raise ValueError('installed evidence changed during readback')
    gate.recheck(plan)
    return {'schemaVersion': 1, 'state': 'inspected-unqualified-producer',
            'operationsSHA256': gate.sha(raw), 'outputs': outputs}


def main():
    if len(sys.argv) != 5: raise ValueError('usage: verify_installed_guest_effects evidence blobs roots-json Bundle-Resources')
    evidence, blobs, roots_json, resources = sys.argv[1:]
    plan = gate.from_environment()
    roots = {name: Path(path) for name, path in json.loads(roots_json).items()}
    print(json.dumps(verify(plan, Path(evidence), Path(blobs), roots, Path(resources)), sort_keys=True))

if __name__ == '__main__': main()

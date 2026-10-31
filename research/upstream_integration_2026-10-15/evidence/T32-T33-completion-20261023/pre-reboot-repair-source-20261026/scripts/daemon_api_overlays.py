#!/usr/bin/env python3
"""Apply only declared, hash-bound overlays to the isolated pinned guest graph."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / 'dependencies/daemon-api-overlays'


def git(repo, *args):
    return subprocess.check_output(['/usr/bin/git','-C',str(repo),*args],stderr=subprocess.PIPE)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inspect(repo, overlay, patch):
    path = Path(overlay['path'])
    if repo.is_symlink() or not repo.is_dir() or path.is_absolute() or '..' in path.parts:
        raise ValueError('Unsafe overlay source path')
    source = repo / path
    cursor = source
    while cursor != repo:
        if cursor.is_symlink():
            raise ValueError('Overlay source must not traverse a symlink')
        cursor = cursor.parent
    if git(repo,'rev-parse','HEAD').decode().strip() != overlay['revision']:
        raise ValueError('Overlay revision mismatch')
    if patch.is_symlink() or digest(patch.read_bytes()) != overlay['patch_sha256']:
        raise ValueError('Overlay patch mismatch')
    if digest(git(repo,'show','HEAD:'+overlay['path'])) != overlay['base_sha256']:
        raise ValueError('Overlay committed source mismatch')
    status = git(repo,'status','--porcelain','-z','--untracked-files=all')
    allowed = b' M '+overlay['path'].encode()+b'\0'
    if status not in (b'',allowed):
        raise ValueError('Unexpected dependency checkout modification')
    return source, digest(source.read_bytes())


def validate_overlay(repo, overlay, patch):
    _, sha = inspect(repo,overlay,patch)
    if sha != overlay['patched_sha256']:
        raise ValueError('Compiled dependency overlay mismatch')
    return dict(overlay)


def apply_overlay(repo, overlay, patch):
    source, sha = inspect(repo,overlay,patch)
    if sha == overlay['patched_sha256']:
        return validate_overlay(repo,overlay,patch)
    if sha != overlay['base_sha256']:
        raise ValueError('Modified overlay source; refusing overwrite')
    stats = git(repo,'apply','--numstat',str(patch)).decode().splitlines()
    if len(stats)!=1 or stats[0].split('\t')[-1] != overlay['path']:
        raise ValueError('Overlay patch must modify its declared file only')
    git(repo,'apply','--check',str(patch))
    original = source.read_bytes()
    try:
        git(repo,'apply',str(patch))
        return validate_overlay(repo,overlay,patch)
    except Exception:
        source.write_bytes(original)
        raise


def fingerprint(overlays):
    return digest(json.dumps(overlays,sort_keys=True,separators=(',',':')).encode())


def marker(overlays):
    return 'VPHONE_DAEMON_OVERLAYS:'+fingerprint(overlays)


def validate_marker(binary, overlays):
    if marker(overlays).encode() not in binary:
        raise ValueError('Candidate binary source overlay marker mismatch')


def declarations():
    return json.loads((DIRECTORY/'manifest.json').read_text())['overlays']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkouts',type=Path)
    parser.add_argument('--fingerprint',action='store_true')
    args=parser.parse_args()
    if args.fingerprint:
        print(fingerprint(declarations()))
        return
    if args.checkouts is None:parser.error('--checkouts is required when applying overlays')
    for overlay in declarations():
        apply_overlay(args.checkouts/overlay['identity'],overlay,DIRECTORY/overlay['patch'])
    print('Declared daemon source overlays applied and verified')


if __name__=='__main__':main()

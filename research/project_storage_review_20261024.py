"""Read-only package/archive comparison for the project storage assessment."""
import hashlib
import json
import os
from pathlib import Path
import stat
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'research/evidence/project-storage-review-20261024'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def compare(directory, archive, expected, frozen):
    bundle = directory / 'VPhone.bundle'
    if directory.is_symlink() or archive.is_symlink() or bundle.is_symlink():
        raise ValueError('Linked package or archive')
    if {path.name for path in directory.iterdir()} != {'VPhone.bundle'}:
        raise ValueError('Package directory includes other unarchived entries')
    if sha(archive) != expected:
        raise ValueError('Retained archive digest differs')
    seen = set()
    count = 0
    with tarfile.open(archive) as tar:
        for member in tar:
            parts = Path(member.name).parts
            if any(part.startswith('._') for part in parts):
                continue
            if not parts or parts[0] != 'VPhone.bundle' or '..' in parts:
                raise ValueError('Unexpected archive member')
            name = str(Path(member.name))
            if name in seen:
                raise ValueError('Duplicate archive member')
            seen.add(name)
            path = directory / name
            info = path.lstat()
            if member.isfile():
                if not stat.S_ISREG(info.st_mode) or info.st_size != member.size:
                    raise ValueError('Different type/size: ' + name)
                with tar.extractfile(member) as stream:
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                if sha(path) != digest or stat.S_IMODE(info.st_mode) != member.mode:
                    raise ValueError('Different content/mode: ' + name)
                count += 1
            elif member.issym():
                if not path.is_symlink() or os.readlink(path) != member.linkname:
                    raise ValueError('Different symbolic link: ' + name)
            elif not member.isdir() or not stat.S_ISDIR(info.st_mode):
                raise ValueError('Unsupported archive member: ' + name)
    actual = {str(p.relative_to(directory)) for p in bundle.rglob('*')}
    if actual - seen:
        raise ValueError('Package includes unarchived entries')
    references = [name for name in frozen if Path(name) == directory or directory in Path(name).parents]
    allocated = sum(p.lstat().st_blocks * 512 for p in [directory, *directory.rglob('*')])
    return dict(directory=str(directory.relative_to(ROOT)), archive=str(archive.relative_to(ROOT)),
                archiveSHA256=expected, verifiedFiles=count, allocatedBytes=allocated,
                currentPlanFrozenReferences=references, matched=True,
                scope='file contents, file modes, member types and symlinks; no deletion authorized')


def main():
    OUT.mkdir(exist_ok=True)
    output = OUT / 'package-comparison.json'
    if output.exists():
        raise ValueError('Preserve an existing assessment')
    plan = ROOT / '.build/t32-t33-completion-20261023/origin-identity-acceptance-20261024-r2/offline-plan.json'
    frozen = json.loads(plan.read_text())['frozenInputs']
    old = json.loads((ROOT / 'research/evidence/t32-t33-storage-review-20261024/cleanup-bundle-verification-20261024.json').read_text())
    sources = [(Path(row['directory']), Path(row['archive']), row['archiveSHA256']) for row in old]
    for name in [
        '.build/t52-consumer-fix-20261022/candidate.json',
        '.build/t52-consumer-fix-20261022/candidate-r1.json',
        '.build/t52-camera-interface-20261022/candidate.json',
        '.build/t52-camera-diagnostics-20261022/candidate.json',
        '.build/t52-real-20261021/core-bundle-candidate.json',
        '.build/t52-api-proxy-deploy-20261022/candidate.json',
    ]:
        record = json.loads((ROOT / name).read_text())
        sources.append((Path(record['bundle']).parent, Path(record['archive']), record['archiveSHA256']))
    rows = []
    for directory, archive, expected in sources:
        try:
            row = compare(directory, archive, expected, frozen)
        except (ValueError, OSError, KeyError, tarfile.TarError) as error:
            row = dict(directory=str(directory), matched=False, error=str(error))
        rows.append(row)
        print(json.dumps(row), flush=True)
    output.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()

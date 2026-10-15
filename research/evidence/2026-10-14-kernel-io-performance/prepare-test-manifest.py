"""Keep unchanged target declarations needed for the isolated performance tests.

Run only on /private/tmp/vphone-kernel-io-* copies. The full manifest is saved
exclusively before replacement. No production target sources are changed.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat


def close(text, start, opening, closing):
    level, quoted, escape = 0, False, False
    for index in range(start, len(text)):
        char = text[index]
        if quoted:
            if escape: escape = False
            elif char == '\\': escape = True
            elif char == '"': quoted = False
            continue
        if char == '"': quoted = True
        elif char == opening: level += 1
        elif char == closing:
            level -= 1
            if level == 0: return index
    raise ValueError('unbalanced manifest')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--label', required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    assert root.parent == Path('/private/tmp') and root.name.startswith('vphone-kernel-io-')
    root_lock = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    fcntl.flock(root_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    assert re.fullmatch('[a-z0-9]+(?:-[a-z0-9]+)*', args.label)
    evidence = Path(__file__).resolve().parent
    path = root / 'Package.swift'
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    before = os.fstat(fd)
    assert stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 < before.st_size <= 1 << 20
    keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_nlink')
    def identity(value): return tuple(getattr(value, key) for key in keys)
    original_raw = os.read(fd, (1 << 20) + 1)
    assert len(original_raw) == before.st_size and identity(os.fstat(fd)) == identity(os.lstat(path)) == identity(before)
    original = original_raw.decode()
    assert not os.path.lexists(evidence / (args.label + '-manifest.json'))
    with (evidence / (args.label + '-Package-full.swift')).open('x') as output: output.write(original)
    start = original.index('[', original.index('    dependencies:'))
    dependencies = original[start:close(original, start, '[', ']') + 1]
    source = original[original.index('    targets:'):]
    wanted = {'VPhoneArchiveKit', 'VPhoneCore', 'VPhoneBundleStore', 'FirmwarePatcher',
              'FirmwarePatcherTests', 'VPhoneBundleStoreTests'}
    if 'name: "VPhoneKernelIOTrace"' in source:
        wanted.update({'VPhoneKernelIOTrace', 'VPhoneKernelIOTraceTests'})
    declarations = {}
    for match in re.finditer(r'\.(?:target|testTarget)\(', source):
        end = close(source, match.end() - 1, '(', ')')
        declaration = source[match.start():end + 1]
        name = re.match(r'\.(?:target|testTarget)\(\s*name:\s*"([^"]+)"', declaration)
        assert name
        if name[1] in wanted: declarations[name[1]] = declaration
    assert set(declarations) == wanted
    replacement = ('// swift-tools-version:6.0\nimport PackageDescription\n\n'
                   'let package = Package(name: "vphone-cli", defaultLocalization: "en", platforms: [.macOS(.v15)],\n'
                   '    products: [.library(name: "FirmwarePatcher", targets: ["FirmwarePatcher"])],\n'
                   '    dependencies: ' + dependencies + ',\n    targets: [\n        '
                   + ',\n        '.join(declarations.values()) + '\n    ])\n')
    metadata = dict(root=str(root), targets=sorted(wanted),
                    original_sha256=hashlib.sha256(original.encode()).hexdigest(),
                    test_manifest_sha256=hashlib.sha256(replacement.encode()).hexdigest(),
                    target_declaration_sha256={name: hashlib.sha256(value.encode()).hexdigest()
                                               for name, value in declarations.items()},
                    scope='Target declarations and all package dependencies unchanged; unrelated targets/products excluded.')
    with (evidence / (args.label + '-manifest.json')).open('x') as output:
        json.dump(metadata, output, indent=2); output.write('\n')
    # Both exclusive evidence outputs exist before the isolated file is changed.
    assert identity(os.fstat(fd)) == identity(os.lstat(path)) == identity(before)
    os.lseek(fd, 0, os.SEEK_SET)
    assert os.read(fd, (1 << 20) + 1) == original_raw
    os.lseek(fd, 0, os.SEEK_SET)
    data = replacement.encode(); written = 0
    while written < len(data):
        amount = os.write(fd, data[written:]); assert amount > 0; written += amount
    os.ftruncate(fd, len(data))
    after = os.fstat(fd); named = os.lstat(path)
    assert after.st_dev == named.st_dev == before.st_dev and after.st_ino == named.st_ino == before.st_ino
    assert stat.S_ISREG(named.st_mode) and named.st_nlink == 1
    os.lseek(fd, 0, os.SEEK_SET); assert os.read(fd, (1 << 20) + 1) == data
    os.close(fd)
    os.close(root_lock)
    print(json.dumps(metadata))


if __name__ == '__main__': main()

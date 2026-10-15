"""Build four isolated release artifacts with recorded, identical input contracts."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

E = Path(__file__).resolve().parent
PROJECT = E.parents[2]
BUILD = Path('/private/tmp/vphone-kernel-io-factorial-build-20261014')
BEFORE = PROJECT / 'research/evidence/2026-10-14-kernel-io-fusion/before'
FILES = ['sources/FirmwarePatcher/Pipeline/FirmwareKernelDisk.swift',
         'sources/FirmwarePatcher/Pipeline/FirmwareKernelMount.swift',
         'sources/FirmwarePatcher/Pipeline/FirmwareKernelUpdate.swift']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('VPHONE_TEST_', 'VPHONE_LESS_', 'VPHONE_C4_', 'VPHONE_KERNEL_',
                                  'VPHONE_MOUNT_', 'VPHONE_DSC_'))}
    env['CLANG_MODULE_CACHE_PATH'] = str(BUILD / '.modulecache')
    env['SWIFT_MODULECACHE_PATH'] = str(BUILD / '.modulecache')
    command = ['swift', 'test', '--package-path', str(BUILD), '--scratch-path', str(BUILD / '.build'),
               '--cache-path', str(BUILD / '.swiftpm-cache'), '--disable-automatic-resolution',
               '--disable-sandbox', '-c', 'release', '--filter', 'FirmwareKernelIOFactorialBenchmarkTests|FirmwareKernelIOBenchmarkTests']
    variants = []
    for name, second, third in [('baseline', False, False), ('second', True, False),
                                ('third', False, True), ('combined', True, True)]:
        root = Path('/private/tmp/vphone-kernel-io-factorial-' + name + '-20261014')
        root.mkdir(exist_ok=False)
        for relative in FILES:
            current = third if relative.endswith('FirmwareKernelDisk.swift') else second
            shutil.copyfile((PROJECT if current else BEFORE) / relative, BUILD / relative)
        sources = [path for folder in ['sources', 'tests', 'scripts', 'vendor']
                   for path in (BUILD / folder).rglob('*') if path.is_file()
                   and '.git' not in path.parts and '__pycache__' not in path.parts]
        sources += [BUILD / 'Package.swift', BUILD / 'Package.resolved']
        manifest = {str(path.relative_to(BUILD)): digest(path) for path in sources}
        (E / (name + '-build-inputs.json')).write_text(json.dumps(manifest, indent=2) + '\n')
        print('building ' + name, flush=True)
        started = time.monotonic()
        with (E / (name + '-build.log')).open('x') as log:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        record = dict(command=command, exit_code=result.returncode, elapsed_seconds=time.monotonic() - started,
                      source_manifest_sha256=digest(E / (name + '-build-inputs.json')),
                      module_cache=env['CLANG_MODULE_CACHE_PATH'])
        (E / (name + '-build.json')).write_text(json.dumps(record, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError('Build failed for ' + name)
        assert all(digest(BUILD / path) == value for path, value in manifest.items()), 'Build source changed'
        for folder in ['sources', 'tests', 'scripts']:
            subprocess.run(['/bin/cp', '-cR', str(BUILD / folder), str(root / folder)], check=True)
        shutil.copyfile(BUILD / 'Package.swift', root / 'Package.swift')
        shutil.copyfile(BUILD / 'Package.resolved', root / 'Package.resolved')
        release = Path('.build/arm64-apple-macosx/release')
        (root / release.parent).mkdir(parents=True)
        subprocess.run(['/bin/cp', '-cR', str(BUILD / release), str(root / release)], check=True)
        bundle = root / release / 'vphone-cliPackageTests.xctest'
        binary = bundle / 'Contents/MacOS/vphone-cliPackageTests'
        item = dict(name=name, second=second, third=third, root=str(root), bundle=str(bundle),
                    compiled_source_root=str(BUILD), binary_sha256=digest(binary),
                    package_sha256=digest(root / 'Package.swift'),
                    benchmark_test_sha256=digest(root / 'tests/FirmwarePatcherTests/FirmwareKernelIOFactorialBenchmarkTests.swift'),
                    capture_test_sha256=digest(root / 'tests/FirmwarePatcherTests/FirmwareKernelIOBenchmarkTests.swift'),
                    source_manifest=str(E / (name + '-build-inputs.json')),
                    source_manifest_sha256=digest(E / (name + '-build-inputs.json')),
                    build_record=str(E / (name + '-build.json')),
                    build_record_sha256=digest(E / (name + '-build.json')),
                    build_flags=dict(configuration='release', language='swift-tools-version:6.0',
                                     platform='macOS15', automatic_resolution=False))
        variants.append(item)
        print(json.dumps(dict(name=name, seconds=record['elapsed_seconds'], binary_sha256=item['binary_sha256'])), flush=True)
    tool = Path('/Applications/Xcode.app/Contents/Developer/usr/bin/xctest')
    (E / 'variants.json').write_text(json.dumps(dict(variants=variants, xctest=str(tool),
        xctest_sha256=digest(tool), scope='Four frozen synthetic artifacts, common recorded compilation path'), indent=2) + '\n')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Seal the single-library provider candidate, without installing or booting."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-provider-fix-20261023'
BASE = ROOT / '.build/t52-consumer-fix-20261022/package-r2/VPhone.bundle'
BUNDLE = WORK / 'package/VPhone.bundle'
sys.path.insert(0, str(ROOT / 'scripts'))
import check_guest_components


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args): subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    if BUNDLE.exists(): raise ValueError('Preserve the sealed candidate')
    BUNDLE.parent.mkdir()
    run('/usr/bin/ditto', BASE, BUNDLE)
    resources = BUNDLE / 'Contents/Resources'
    stage = resources / '.build/guest-components-v2/stage'
    library = 'vcamcaptured/libvcamcaptured.dylib'
    shutil.copy2(WORK / 'siblings/stage' / library, stage / library)
    pins = json.loads((ROOT / 'dependencies/guest-components-pins.json').read_text())
    check_guest_components.check_sources(pins)
    report = check_guest_components.inspect(stage, pins)
    (stage / 'manifest.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    shutil.copy2(ROOT / 'dependencies/guest-components-pins.json', resources / 'dependencies/guest-components-pins.json')
    provenance = dict(baseVersion='2.6.2-local.cc05d88f441f',
        changedGuestLibraries=['libvcamcaptured.dylib'],
        sourceSHA256={entry['local']: sha(ROOT / entry['local']) for entry in pins['files']},
        actualGuestProbe='provider-fallback-test-r1: native shared nil, native fallback instance and one matching backing',
        QRConsumerValidated=False, installed=False)
    (resources / 'source-provider-fix-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    run('/usr/bin/codesign', '--force', '--sign', '-', BUNDLE)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/record_build_dependencies.py', BUNDLE)
    run('/usr/bin/codesign', '--force', '--sign', '-', BUNDLE)
    run(ROOT / '.venv/bin/python', '-B', ROOT / 'scripts/check_bundle.py', BUNDLE)
    version = '2.6.2-local.' + sha(resources / 'build-dependencies.json')[:12]
    archive = WORK / (version + '.tar')
    run('/usr/bin/tar', '-cf', archive, '-C', BUNDLE.parent, 'VPhone.bundle')
    before = {str(p.relative_to(BASE)): sha(p) for p in BASE.rglob('*') if p.is_file()}
    after = {str(p.relative_to(BUNDLE)): sha(p) for p in BUNDLE.rglob('*') if p.is_file()}
    protected = ['Contents/MacOS/vphone-vm'] + [name for name in before if name.startswith('Contents/Frameworks/') or name.startswith('Contents/Resources/guest-resources/') or name.startswith('Contents/Resources/.build/daemon-api-v2/')]
    for name in protected: assert before[name] == after[name], name
    for name in check_guest_components.ARTIFACTS:
        if name != library: assert sha(stage / name) == sha(BASE / 'Contents/Resources/.build/guest-components-v2/stage' / name)
    result = dict(state='prepared_not_installed', version=version, bundle=str(BUNDLE),
        archive=str(archive), archiveSHA256=sha(archive), archiveBytes=archive.stat().st_size,
        librarySHA256=sha(stage / library), hostVMUnchanged=True,
        hostVMCDHash='89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541',
        APIAndPublishersUnchanged=True, otherGuestLibrariesUnchanged=True,
        changedPaths=[name for name in sorted(before.keys() | after.keys()) if before.get(name) != after.get(name)],
        provenance=provenance)
    (WORK / 'candidate.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['state', 'version', 'archiveSHA256', 'archiveBytes', 'librarySHA256']}))


if __name__ == '__main__': main()

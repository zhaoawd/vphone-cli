#!/usr/bin/env python3
"""Record the build toolchain, source revisions and bundled asset digests."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
bundle = Path(sys.argv[1]).resolve()
resources = bundle / 'Contents/Resources'


def output(*args):
    return subprocess.check_output(args, cwd=root, text=True, stderr=subprocess.STDOUT).strip()


report = {
    'schema_version': 1,
    'commit': output('git', 'rev-parse', 'HEAD'),
    'submodules': output('git', 'submodule', 'status', '--recursive'),
    'swift': output('swift', '--version'),
    'xcode': output('xcodebuild', '-version'),
    'host': output('sw_vers'),
    'package_resolved_sha256': hashlib.sha256((root / 'Package.resolved').read_bytes()).hexdigest(),
    'files_sha256': {},
    'host_tool_libraries': {},
}
for path in sorted(resources.rglob('*')):
    if path.is_file() and path.name != 'build-dependencies.json':
        report['files_sha256'][str(path.relative_to(resources))] = hashlib.sha256(path.read_bytes()).hexdigest()
for path in [resources / '.tools/bin/trustcache', resources / '.tools/bin/insert_dylib', bundle / 'Contents/MacOS/ldid']:
    report['host_tool_libraries'][str(path.relative_to(bundle))] = output('otool', '-L', str(path))
(resources / 'build-dependencies.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')

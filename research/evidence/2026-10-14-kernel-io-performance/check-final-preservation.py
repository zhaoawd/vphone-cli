"""Read source/artifact hashes only. The recorded parent holds the Task 8 guard."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path

E = Path(__file__).resolve().parent
R = E.parents[2]
spec = importlib.util.spec_from_file_location('benchmark_contract', E / 'run-benchmarks.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

snapshot = json.loads((E / 'baseline-source-copy.json').read_text())
for item in snapshot['files']:
    assert Path(item['path']).name != 'TODO.md'
    assert digest(R / item['path']) == item['sha256'], item['path']
v9 = json.loads((R / 'research/evidence/2026-10-13-task8/acceptance/kernel-rollback/manifest.json').read_text())
assert len(v9['sourceFiles']) == 16
for item in v9['sourceFiles']: assert digest(R / item['path']) == item['sha256']
cli = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.20261021-local/VPhone.bundle/Contents/MacOS/vphone-cli')
cli_sha = digest(cli)
assert cli_sha == 'e1c6ca75c19966ec8bcada05ca235c1e5019c572570b64e8ebed041f0d14da76'
manifest = json.loads((E / 'benchmark-variants.json').read_text())
fds, source_counts = [], {}
try:
    for variant in manifest['variants']:
        fd = os.open(variant['root'], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        fds.append(fd); fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    bench.validate_variants(manifest)
    for variant in manifest['variants']:
        sources = json.loads((E / (variant['name'] + '-benchmark-source-manifest.json')).read_text())
        for path, expected in sources.items(): assert digest(Path(variant['root']) / path) == expected
        source_counts[variant['name']] = len(sources)
finally:
    for fd in fds: os.close(fd)
review = json.loads((E / 'benchmark-controller-independent-review-final.json').read_text())
for path, expected in review['sources_sha256'].items(): assert digest(E / path) == expected
result = dict(passed=True, shared_files_checked=len(snapshot['files']), frozen_v9_sources_checked=16,
              installed_v9_cli_sha256=cli_sha, isolated_source_files_checked=source_counts,
              three_variants_actual_binary_package_source_test_build_and_tool_hashes=True,
              controller_tools_unchanged=True, scope='No VM disk content read, no Store mutation, no VM/AMFI action')
with (E / 'final-preservation-check.json').open('x') as output:
    json.dump(result, output, indent=2); output.write('\n')
print(json.dumps(result))

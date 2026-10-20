"""Run the standard Swift entrypoint's trailing checks after a recorded failure."""
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(root / 'scripts'))
from run_tests import LATENCY_TESTS

out = Path(__file__).resolve().parent
env = os.environ.copy()
for name in list(env):
    if name.startswith(('VPHONE_TEST_', 'VPHONE_LESS_', 'VPHONE_C4_')):
        del env[name]
for name in ('CLANG_MODULE_CACHE_PATH', 'SWIFT_MODULECACHE_PATH'):
    env[name] = str(root / '.build/test-module-cache')
checks = [
    ('latency', ['swift', 'test', '--disable-sandbox', '--cache-path', str(root / '.build/test-cache'), '--skip-build', '--filter', LATENCY_TESTS]),
    ('tar-memory', [sys.executable, 'scripts/check_tar_pipe_memory.py']),
    ('digest-memory', [sys.executable, 'scripts/check_file_digest_memory.py']),
    ('guest-components', ['make', 'test_guest_components']),
]
results = []
for label, command in checks:
    with (out / (label + '-host.log')).open('wb') as log:
        result = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
    results.append({'name': label, 'command': command, 'exit_code': result.returncode, 'log': label + '-host.log'})
    (out / 'followup-results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(label + ': ' + str(result.returncode), flush=True)
sys.exit(0 if all(row['exit_code'] == 0 for row in results) else 1)

import importlib.util
import os
import sys
from pathlib import Path
root = Path('/private/tmp/vphone-task4-validation-20261012')
spec = importlib.util.spec_from_file_location('standard_runner', root / 'scripts/run_tests.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
env = os.environ.copy()
for name in list(env):
    if name.startswith(('VPHONE_TEST_', 'VPHONE_LESS_', 'VPHONE_C4_')):
        del env[name]
env.setdefault('CLANG_MODULE_CACHE_PATH', str(root / '.build/test-module-cache'))
env.setdefault('SWIFT_MODULECACHE_PATH', str(root / '.build/test-module-cache'))
runner.run([sys.executable, root / 'scripts/check_tar_pipe_memory.py'], env=env)
runner.run([sys.executable, root / 'scripts/check_file_digest_memory.py'], env=env)
runner.run(['make', 'test_guest_components'], env=env)

#!/usr/bin/env python3
"""运行 B35 定向回归；使用仓库内模块缓存，不启动 VM。"""
import importlib.util
import os
from pathlib import Path
import sys
import unittest

repo = Path(__file__).resolve().parents[5]
cache = str(repo / '.build/research-b35/test-module-cache')
os.environ['CLANG_MODULE_CACHE_PATH'] = cache
os.environ['SWIFTPM_MODULECACHE_OVERRIDE'] = cache
fs = os.statvfs(repo)
assert fs.f_bavail * fs.f_frsize >= 5 * 1024**3, 'STOP: disk below 5 GiB'
suite = unittest.TestSuite()
for name in ('test_bootstrap_startup', 'test_guest_bootstrap_state', 'test_daemon_api_build',
             'test_daemon_api_overlays', 'test_daemon_api_icli'):
    spec = importlib.util.spec_from_file_location(name, repo / 'tests' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(not result.wasSuccessful())

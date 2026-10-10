#!/usr/bin/env python3
"""项目 unittest 定向回归；固定依赖由明确路径提供，只运行离线测试。"""
import json
from pathlib import Path
import sys
import unittest

repo = Path(__file__).resolve().parents[5]
sys.path.insert(0, str(repo / 'tests'))
suite = unittest.TestSuite()
for name in ('test_t08_workspace', 'test_bootstrap_startup', 'test_guest_bootstrap_state',
             'test_daemon_api_build', 'test_daemon_api_overlays', 'test_daemon_api_icli',
             'test_guest_components', 'test_injection_environment', 'test_t08_rotation_probe'):
    module = __import__(name)
    suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
module = __import__('test_cfw_env_update')
for name in ('AssessTests', 'ApplyMountedTests', 'ManifestConsistencyTests'):
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(getattr(module, name)))
result = unittest.TextTestRunner(verbosity=2).run(suite)
record = {'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
          'skips': len(result.skipped), 'success': result.wasSuccessful(),
          'scope': 'host functions, pinned dependency code, synthetic directory fixtures; no VM'}
Path(__file__).with_name('regression-result.json').write_text(json.dumps(record, indent=2) + '\n')
# 固定依赖实际检查必须执行；跳过测试不能作为成功证据。
sys.exit(0 if result.wasSuccessful() and not result.skipped else 1)

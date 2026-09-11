"""Syntax failures must fail CI without executing project scripts."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CHECK = Path(__file__).resolve().parents[1] / 'scripts/check_scripts.py'


class ScriptChecksTests(unittest.TestCase):
    def check(self, suffix, source):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ('fixture' + suffix)
            path.write_text(source)
            return subprocess.run([sys.executable, str(CHECK), str(path)], capture_output=True, text=True)

    def test_python_syntax_failure_is_nonzero(self):
        result = self.check('.py', 'def broken(:\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fixture.py', result.stderr)

    def test_shell_syntax_failure_is_nonzero(self):
        result = self.check('.sh', '#!/bin/zsh\nif then\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fixture.sh', result.stderr)

    def test_valid_scripts_are_not_executed(self):
        for suffix, source in [('.py', 'raise RuntimeError("must not run")\n'),
                               ('.sh', '#!/bin/zsh\nexit 91\n')]:
            result = self.check(suffix, source)
            self.assertEqual(result.returncode, 0, result.stderr)

"""Check the runnable entrypoint without starting a VM or helper."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import observe_t32_budgeted_runtime as entry
import t32_runtime_rpc_transport as transport


class BudgetedRuntimeEntrypointTests(unittest.TestCase):
    digest = 'a' * 64

    def test_existing_wrapper_import_pattern_from_an_unrelated_directory(self):
        source = Path(entry.__file__).resolve()
        script = ('import importlib.util\n'
                  f'spec=importlib.util.spec_from_file_location("prepared_observer",{str(source)!r})\n'
                  'module=importlib.util.module_from_spec(spec)\n'
                  'spec.loader.exec_module(module)\n'
                  'module.main(["--help"])\n')
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, '-I', '-B', '-c', script], cwd=temporary,
                                    capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--work-directory', result.stdout)

    def test_work_transport_and_exact_plan_reach_observer(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary).resolve()
            original = sys.argv
            received = {}
            module = SimpleNamespace()

            def execute():
                received.update(work=module.WORK, request=module.request, argv=sys.argv[:])
                return 7

            module.main = execute
            with patch.object(entry, 'load_observer', return_value=module):
                result = entry.main(['--work-directory', str(work),
                                     '--execute-approved-runtime-plan', self.digest])
            self.assertEqual(result, 7)
            self.assertEqual(received['work'], work)
            self.assertIs(received['request'], transport.request)
            self.assertEqual(received['argv'][1:], ['--execute-approved-runtime-plan', self.digest])
            self.assertIs(sys.argv, original)

    def test_real_approval_gate_precedes_vm_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary).resolve()
            (work / 'boot-window').mkdir()
            module = entry.load_observer()
            original = sys.argv
            with patch.object(entry, 'load_observer', return_value=module), \
                 patch.object(module.subprocess, 'Popen') as start, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(entry.main(['--work-directory', str(work),
                    '--execute-approved-runtime-plan', self.digest]), 1)
            start.assert_not_called()
            self.assertFalse((work / 'runtime-observation').exists())
            self.assertIs(sys.argv, original)

    def test_explicit_digest_is_required_before_observer_load(self):
        with patch.object(entry, 'load_observer') as load, \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                entry.main(['--work-directory', '/private/tmp',
                            '--execute-approved-runtime-plan', 'fixture'])
        load.assert_not_called()

    def test_exception_restores_argv(self):
        with tempfile.TemporaryDirectory() as temporary:
            original = sys.argv
            module = SimpleNamespace(main=lambda: (_ for _ in ()).throw(ValueError('fixture')))
            with patch.object(entry, 'load_observer', return_value=module):
                with self.assertRaisesRegex(ValueError, 'fixture'):
                    entry.main(['--work-directory', str(Path(temporary).resolve()),
                                '--execute-approved-runtime-plan', self.digest])
            self.assertIs(sys.argv, original)


if __name__ == '__main__':
    unittest.main()

from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=root/'tests/test_bundle_native_dependencies.py'
s=p.read_text().replace('import importlib.util\n','')
s=s.replace("    def test_check_rejects_resolvable_external_dependencies(self):\n        result", "    def test_check_rejects_resolvable_external_dependencies(self):\n        self.run_tool('install_name_tool', '-delete_rpath', self.external, self.tool)\n        result")
# A surviving build-machine rpath is a separate portability failure.
s=s.replace('    def test_missing_dependency_fails_before_success(self):', '''    def test_check_rejects_external_rpath_with_internal_dependencies(self):
        result = self.script()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.run_tool('install_name_tool', '-add_rpath', self.external, self.tool)
        result = self.script('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Nonportable rpath', result.stdout)

    def test_conflicting_existing_library_fails_instead_of_reusing_stale_bytes(self):
        frameworks = self.app / 'Contents/Frameworks'
        frameworks.mkdir()
        (frameworks / 'libparent.dylib').write_bytes(b'stale build')
        result = self.script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Conflicting native library', result.stdout)

    def test_missing_dependency_fails_before_success(self):''')
p.write_text(s)

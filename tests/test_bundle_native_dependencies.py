"""Exercise relocatable host dependency closure with real signed Mach-O fixtures."""
from pathlib import Path
import shutil
import hashlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/build_native_dependencies.py'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'requires macOS toolchain')
class NativeDependencyBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vphone-native-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.app = self.base / 'test.app'
        self.tool = self.app / 'Contents/MacOS/ldid'
        self.tool.parent.mkdir(parents=True)
        self.external = self.base / 'external'
        self.external.mkdir()
        (self.external / 'leaf.c').write_text('int leaf(void) { return 37; }\n')
        (self.external / 'parent.c').write_text('extern int leaf(void); int parent(void) { return leaf() + 5; }\n')
        (self.external / 'main.c').write_text('#include <stdio.h>\nextern int parent(void); int main(void) { printf("%d\\n", parent()); return 0; }\n')
        self.leaf = self.external / 'libleaf.dylib'
        self.parent = self.external / 'libparent.dylib'
        self.run_tool('clang', '-dynamiclib', self.external / 'leaf.c', '-o', self.leaf,
                      '-Wl,-install_name,' + str(self.leaf), '-Wl,-headerpad_max_install_names')
        self.run_tool('clang', '-dynamiclib', self.external / 'parent.c', self.leaf, '-o', self.parent,
                      '-Wl,-install_name,' + str(self.parent), '-Wl,-headerpad_max_install_names')
        self.run_tool('clang', self.external / 'main.c', self.parent, '-o', self.tool,
                      '-Wl,-headerpad_max_install_names', '-Wl,-rpath,' + str(self.external))

    def run_tool(self, *args):
        return subprocess.check_output([str(a) for a in args], text=True, stderr=subprocess.STDOUT)

    def script(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.app), *args],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_check_rejects_resolvable_external_dependencies(self):
        self.run_tool('install_name_tool', '-delete_rpath', self.external, self.tool)
        result = self.script('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('External dependency', result.stdout)

    def test_relocated_recursive_libraries_execute_and_verify_without_originals(self):
        result = self.script()
        self.assertEqual(result.returncode, 0, result.stdout)
        frameworks = self.app / 'Contents/Frameworks'
        self.assertTrue((frameworks / 'libleaf.dylib').is_file())
        self.assertTrue((frameworks / 'libparent.dylib').is_file())
        self.assertIn('@loader_path/../Frameworks/libparent.dylib', self.run_tool('otool', '-L', self.tool))
        self.assertIn('@loader_path/libleaf.dylib', self.run_tool('otool', '-L', frameworks / 'libparent.dylib'))
        self.assertIn('@rpath/libleaf.dylib', self.run_tool('otool', '-D', frameworks / 'libleaf.dylib'))
        self.assertNotIn(str(self.external), self.run_tool('otool', '-l', self.tool))
        shutil.rmtree(self.external)
        moved = self.base / 'relocated app.app'
        self.app.rename(moved)
        self.app = moved
        self.assertEqual(self.run_tool(moved / 'Contents/MacOS/ldid').strip(), '42')
        checked = self.script('--check')
        self.assertEqual(checked.returncode, 0, checked.stdout)
        for path in [moved / 'Contents/MacOS/ldid', *sorted((moved / 'Contents/Frameworks').iterdir())]:
            self.run_tool('codesign', '--verify', '--strict', path)

    def test_check_rejects_library_symlink_escape(self):
        result = self.script()
        self.assertEqual(result.returncode, 0, result.stdout)
        library = self.app / 'Contents/Frameworks/libleaf.dylib'
        library.unlink()
        library.symlink_to(self.leaf)
        result = self.script('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('escapes', result.stdout)

    def test_check_rejects_external_rpath_with_internal_dependencies(self):
        result = self.script()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.run_tool('install_name_tool', '-add_rpath', self.external, self.tool)
        result = self.script('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Nonportable rpath', result.stdout)

    def test_check_accepts_loader_and_executable_rpaths_contained_in_bundle(self):
        result = self.script()
        self.assertEqual(result.returncode, 0, result.stdout)
        for rpath in ('@loader_path', '@loader_path/../Frameworks',
                      '@executable_path', '@executable_path/../Frameworks'):
            with self.subTest(rpath=rpath):
                self.run_tool('install_name_tool', '-add_rpath', rpath, self.tool)
                self.run_tool('codesign', '--force', '--sign', '-', self.tool)
                checked = self.script('--check')
                try:
                    self.assertEqual(checked.returncode, 0, checked.stdout)
                finally:
                    self.run_tool('install_name_tool', '-delete_rpath', rpath, self.tool)

    def test_check_rejects_relative_escape_unknown_token_and_symlink_rpaths(self):
        result = self.script()
        self.assertEqual(result.returncode, 0, result.stdout)
        (self.tool.parent / 'escape').symlink_to(self.external, target_is_directory=True)
        for rpath in ('@loader_path/../../../external', '@executable_path/../../../external',
                      '@rpath/Frameworks', 'Frameworks', '@loader_path/escape',
                      '/opt/homebrew/opt/openssl@3/lib'):
            with self.subTest(rpath=rpath):
                self.run_tool('install_name_tool', '-add_rpath', rpath, self.tool)
                self.run_tool('codesign', '--force', '--sign', '-', self.tool)
                checked = self.script('--check')
                self.assertNotEqual(checked.returncode, 0)
                self.assertRegex(checked.stdout, 'Nonportable rpath|escapes')
                self.run_tool('install_name_tool', '-delete_rpath', rpath, self.tool)

    def test_launchpad_native_staging_preserves_embedded_toolchain_bytes(self):
        # Match the assembled Launchpad boundary: two host roots, valid nested
        # app, build-toolchain rpaths, then staging before the final outer seal.
        nested = self.app / 'Contents/Helpers/vphone-cli.app'
        nested_cli = nested / 'Contents/MacOS/vphone-cli'
        nested_cli.parent.mkdir(parents=True)
        source = self.external / 'nested.c'
        source.write_text('int main(void) { return 0; }\n')
        self.run_tool('clang', source, '-o', nested_cli)
        (nested / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'vphone-cli', 'CFBundleIdentifier': 'com.vphone.test.inner',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}))
        self.run_tool('codesign', '--force', '--sign', '-', nested)
        before = {str(p.relative_to(nested)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in nested.rglob('*') if p.is_file()}
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'vphone-launchpad', 'CFBundleIdentifier': 'com.vphone.test.outer',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}))
        for name in ('vphone-launchpad', 'vphone-launchpad-launcher'):
            target = self.tool.parent / name
            shutil.copy2(self.tool, target)
            self.run_tool('install_name_tool', '-add_rpath', '@loader_path', target)
            self.run_tool('install_name_tool', '-add_rpath', '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx', target)
        staged = self.script()
        self.assertEqual(staged.returncode, 0, staged.stdout)
        after = {str(p.relative_to(nested)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in nested.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        self.run_tool('codesign', '--verify', '--strict', '--deep', self.app)
        for name in ('vphone-launchpad', 'vphone-launchpad-launcher'):
            self.assertNotIn('/Applications/Xcode.app', self.run_tool('otool', '-l', self.tool.parent / name))

    def test_recursive_rpath_uses_executable_ancestors_loader_directory(self):
        self.run_tool('install_name_tool', '-change', self.parent, '@rpath/libparent.dylib', self.tool)
        self.run_tool('install_name_tool', '-change', self.leaf, '@rpath/libleaf.dylib', self.parent)
        self.run_tool('install_name_tool', '-delete_rpath', self.external, self.tool)
        self.run_tool('install_name_tool', '-add_rpath', '@loader_path/../../../external', self.tool)
        result = self.script()
        self.assertEqual(result.returncode, 0, result.stdout)
        shutil.rmtree(self.external)
        self.assertEqual(self.run_tool(self.tool).strip(), '42')

    def test_staging_resolves_rpath_with_bare_loader_token(self):
        shutil.copy2(self.parent, self.tool.parent / 'libparent.dylib')
        shutil.copy2(self.leaf, self.tool.parent / 'libleaf.dylib')
        parent = self.tool.parent / 'libparent.dylib'
        self.run_tool('install_name_tool', '-change', self.parent, '@rpath/libparent.dylib', self.tool)
        self.run_tool('install_name_tool', '-delete_rpath', self.external, self.tool)
        self.run_tool('install_name_tool', '-add_rpath', '@loader_path', self.tool)
        self.run_tool('install_name_tool', '-change', self.leaf, '@rpath/libleaf.dylib', parent)
        self.run_tool('install_name_tool', '-add_rpath', '@loader_path', parent)
        staged = self.script()
        self.assertEqual(staged.returncode, 0, staged.stdout)
        shutil.rmtree(self.external)
        self.assertEqual(self.run_tool(self.tool).strip(), '42')

    def test_staging_resolves_library_bare_executable_token_against_host_root(self):
        shutil.copy2(self.leaf, self.tool.parent / 'libleaf.dylib')
        self.run_tool('install_name_tool', '-delete_rpath', self.external, self.tool)
        self.run_tool('install_name_tool', '-change', self.leaf, '@rpath/libleaf.dylib', self.parent)
        self.run_tool('install_name_tool', '-add_rpath', '@executable_path', self.parent)
        staged = self.script()
        self.assertEqual(staged.returncode, 0, staged.stdout)
        shutil.rmtree(self.external)
        self.assertEqual(self.run_tool(self.tool).strip(), '42')

    def test_staging_rejects_referenced_nested_library_without_changing_it(self):
        nested = self.app / 'Contents/Helpers/inner.app/Contents/Frameworks/libembedded.dylib'
        nested.parent.mkdir(parents=True)
        shutil.copy2(self.leaf, nested)
        self.run_tool('install_name_tool', '-id', nested, nested)
        self.run_tool('codesign', '--force', '--sign', '-', nested)
        source = self.external / 'nested-library-main.c'
        source.write_text('extern int leaf(void); int main(void) { return leaf(); }\n')
        self.run_tool('clang', source, nested, '-o', self.tool,
                      '-Wl,-headerpad_max_install_names')
        before = nested.read_bytes()
        staged = self.script()
        self.assertEqual(before, nested.read_bytes())
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn('Nested helper', staged.stdout)

    def test_staging_rejects_outer_root_symlink_to_nested_executable(self):
        nested = self.app / 'Contents/Helpers/inner.app/Contents/MacOS/vphone-cli'
        nested.parent.mkdir(parents=True)
        source = self.external / 'nested-root.c'
        source.write_text('int main(void) { return 0; }\n')
        self.run_tool('clang', source, '-o', nested, '-Wl,-rpath,/opt/homebrew/lib',
                      '-Wl,-headerpad_max_install_names')
        self.tool.unlink()
        self.tool.symlink_to(nested)
        before = nested.read_bytes()
        staged = self.script()
        self.assertEqual(before, nested.read_bytes())
        self.assertNotEqual(staged.returncode, 0)
        self.assertIn('Nested helper', staged.stdout)

    def test_staging_rejects_shared_library_resolution_that_differs_between_roots(self):
        shutil.copy2(self.leaf, self.tool.parent / 'libleaf.dylib')
        other_root = self.app / 'Contents/Resources/.tools/bin/trustcache'
        other_root.parent.mkdir(parents=True)
        source = self.external / 'other-leaf.c'
        source.write_text('int leaf(void) { return 99; }\n')
        other_leaf = other_root.parent / 'libleaf.dylib'
        self.run_tool('clang', '-dynamiclib', source, '-o', other_leaf,
                      '-Wl,-install_name,' + str(other_leaf), '-Wl,-headerpad_max_install_names')
        self.run_tool('install_name_tool', '-change', self.leaf, '@rpath/libleaf.dylib', self.parent)
        self.run_tool('install_name_tool', '-add_rpath', '@executable_path', self.parent)
        self.run_tool('install_name_tool', '-delete_rpath', self.external, self.tool)
        self.run_tool('clang', self.external / 'main.c', self.parent, '-o', other_root,
                      '-Wl,-headerpad_max_install_names')
        for path in (self.parent, self.tool):
            self.run_tool('codesign', '--force', '--sign', '-', path)
        self.assertEqual(self.run_tool(self.tool).strip(), '42')
        self.assertEqual(self.run_tool(other_root).strip(), '104')
        staged = self.script()
        self.assertNotEqual(staged.returncode, 0, staged.stdout)
        self.assertIn('Conflicting dependency resolution', staged.stdout)

    def test_conflicting_existing_library_fails_instead_of_reusing_stale_bytes(self):
        frameworks = self.app / 'Contents/Frameworks'
        frameworks.mkdir()
        stale = self.external / 'stale.c'
        stale.write_text('int parent(void) { return 999; }\n')
        self.run_tool('clang', '-dynamiclib', stale, '-o', frameworks / 'libparent.dylib',
                      '-Wl,-headerpad_max_install_names')
        result = self.script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Conflicting native library', result.stdout)

    def test_main_executable_is_signed_after_nested_host_tools(self):
        info = {'CFBundleIdentifier': 'com.vphone.test.native', 'CFBundleExecutable': 'ldid',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        resource_tool = self.app / 'Contents/Resources/.tools/bin/insert_dylib'
        resource_tool.parent.mkdir(parents=True)
        shutil.copy2(self.tool, resource_tool)
        result = self.script()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.run_tool('codesign', '--verify', '--strict', '--deep', self.app)

    def test_missing_dependency_fails_before_success(self):
        self.leaf.unlink()
        result = self.script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unresolved dependency', result.stdout)


if __name__ == '__main__':
    unittest.main()

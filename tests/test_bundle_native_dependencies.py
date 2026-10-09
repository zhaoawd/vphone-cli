"""Exercise relocatable host dependency closure with real signed Mach-O fixtures."""
from pathlib import Path
import shutil
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

    def test_recursive_rpath_uses_executable_ancestors_loader_directory(self):
        self.run_tool('install_name_tool', '-change', self.parent, '@rpath/libparent.dylib', self.tool)
        self.run_tool('install_name_tool', '-change', self.leaf, '@rpath/libleaf.dylib', self.parent)
        self.run_tool('install_name_tool', '-delete_rpath', self.external, self.tool)
        self.run_tool('install_name_tool', '-add_rpath', '@loader_path/../../../external', self.tool)
        result = self.script()
        self.assertEqual(result.returncode, 0, result.stdout)
        shutil.rmtree(self.external)
        self.assertEqual(self.run_tool(self.tool).strip(), '42')

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

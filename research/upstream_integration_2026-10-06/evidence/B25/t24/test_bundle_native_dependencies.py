"""Exercise relocatable host dependency closure with real signed Mach-O fixtures."""
import importlib.util
from pathlib import Path
import shutil
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

    def test_missing_dependency_fails_before_success(self):
        self.leaf.unlink()
        result = self.script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unresolved dependency', result.stdout)


if __name__ == '__main__':
    unittest.main()

"""Run the default registration-directory contract without LaunchServices mutation."""
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class GuestAppRefreshTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix="vphone refresh ")
        cls.addClassCleanup(cls.temp.cleanup)
        base=Path(cls.temp.name); main=base/"main.swift"; cls.binary=base/"refresh"
        main.write_text(r'''import Foundation
import Darwin
func require(_ condition: Bool) { if !condition { exit(1) } }
func rejects(_ f: () throws -> String) { do { _ = try f(); exit(2) } catch {} }
let mode=CommandLine.arguments[1]
if mode == "missing" {
 rejects { try GuestAppRefreshDirectory.resolve(requested:nil, installation:nil) }
 rejects { try GuestAppRefreshDirectory.resolve(requested:nil, installation:.init(layout:"rootless",root:"/Applications")) }
} else if mode == "layouts" {
 require(try GuestAppRefreshDirectory.resolve(requested:nil,installation:.init(layout:"rootless",root:"/var/jb")) == "/var/jb/Applications")
 require(try GuestAppRefreshDirectory.resolve(requested:nil,installation:.init(layout:"roothide",root:"/private/var/containers/Bundle/Application/.jbroot-000114514191980C")) == "/private/var/containers/Bundle/Application/.jbroot-000114514191980C/Applications")
} else if mode == "explicit" {
 require(try GuestAppRefreshDirectory.resolve(requested:"/Applications",installation:nil) == "/Applications")
 for path in ["", "Applications", "/var/jb/../Applications", "/tmp/\0x"] { rejects { try GuestAppRefreshDirectory.resolve(requested:path,installation:nil) } }
} else { exit(3) }
''')
        paths=[ROOT/"sources/VPhoneDaemon/Daemon"/name for name in ["GuestBootstrapState.swift","GuestAppRefreshDirectory.swift"]]
        result=subprocess.run(["swiftc",*map(str,paths),str(main),"-o",str(cls.binary)],capture_output=True,text=True)
        if result.returncode: raise AssertionError(result.stderr)
    def run_case(self,mode):
        p=subprocess.run([str(self.binary),mode],capture_output=True,text=True,timeout=5)
        self.assertEqual(p.returncode,0,p.stderr)
    def test_missing_or_invalid_bootstrap_cannot_select_a_default(self): self.run_case("missing")
    def test_completed_layout_selects_its_own_applications_directory(self): self.run_case("layouts")
    def test_explicit_absolute_directory_remains_available_without_implicit_fallback(self): self.run_case("explicit")

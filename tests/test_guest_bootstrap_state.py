"""Compile and run the real marker reader against isolated files, without guest writes."""
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
class GuestBootstrapStateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="vphone bootstrap ")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        main = cls.base / "main.swift"
        main.write_text(r'''import Foundation
import Darwin
func require(_ value: Bool) { if !value { exit(1) } }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let primary = root.appendingPathComponent("primary.json")
let legacy = root.appendingPathComponent("legacy.json")
func write(_ object: [String: Any], _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: object).write(to: url)
}
func fails(_ operation: () throws -> Void) { do { try operation(); exit(2) } catch {} }
let mode = CommandLine.arguments[2]
if mode == "preserve" {
    try write(["layout":"rootless", "jbroot":"/var/jb", "password":"unchanged", "host_keys":"unchanged"], legacy)
    let old = try Data(contentsOf: legacy)
    let record = try GuestBootstrapState.read(primary: primary, legacy: legacy)
    require(record?.root == "/var/jb" && record?.layout == "rootless")
    try write(["installed":false], primary)
    require(try GuestBootstrapState.read(primary: primary, legacy: legacy) == nil)
    require(try Data(contentsOf: legacy) == old)
    require(try Data(contentsOf: primary) == Data("{\"installed\":false}".utf8))
} else if mode == "invalid" {
    try write(["layout":"rootless", "jbroot":"/var/jb"], legacy)
    for bytes in [Data("broken".utf8), Data(repeating: 32, count: 65537), Data("{\"installed\":0}".utf8)] {
        try bytes.write(to: primary)
        fails { _ = try GuestBootstrapState.read(primary: primary, legacy: legacy) }
    }
    try FileManager.default.removeItem(at: primary)
    try FileManager.default.createSymbolicLink(at: primary, withDestinationURL: legacy)
    fails { _ = try GuestBootstrapState.read(primary: primary, legacy: legacy) }
} else if mode == "layout" {
    for value in [["layout":"rootless", "jbroot":"/Applications"],
                  ["layout":"roothide", "jbroot":"/private/var/containers/Bundle/Application/.jbroot-0001145141919810"],
                  ["layout":"roothide", "jbroot":"/private/var/containers/Bundle/Application/.jbroot-000114514191980C/../x"]] {
        try write(value, primary)
        fails { _ = try GuestBootstrapState.read(primary: primary, legacy: legacy) }
    }
    try write(["layout":"roothide", "jbroot":"/private/var/containers/Bundle/Application/.jbroot-000114514191980C"], primary)
    require(try GuestBootstrapState.read(primary: primary, legacy: legacy)?.layout == "roothide")
} else { exit(3) }
''')
        cls.binary = cls.base / "reader"
        result = subprocess.run(["swiftc", str(ROOT / "sources/VPhoneDaemon/Daemon/GuestBootstrapState.swift"), str(main), "-o", str(cls.binary)], capture_output=True, text=True)
        if result.returncode: raise AssertionError(result.stderr)
    def run_case(self, mode):
        with tempfile.TemporaryDirectory(dir=self.base) as directory:
            result = subprocess.run([str(self.binary), directory, mode], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
    def test_primary_tombstone_shadows_legacy_without_rewriting_user_state(self): self.run_case("preserve")
    def test_corrupt_numeric_linked_or_oversized_primary_does_not_fall_back(self): self.run_case("invalid")
    def test_invalid_roots_and_checksum_are_refused(self): self.run_case("layout")

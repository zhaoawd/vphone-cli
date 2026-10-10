"""执行实际启动恢复函数；依赖替身仅记录服务加载和文件系统边界。"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'sources/VPhoneDaemon/Daemon/GuestIrisinInstaller.swift'


def method(text, name):
    start = text.index('    static func ' + name + '(')
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == '{':
            depth += 1
        elif text[end] == '}':
            depth -= 1
        end += 1
    return text[start:end]


class BootstrapStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='bootstrap-startup-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        text = SOURCE.read_text()
        functions = method(text, 'refreshBootstrapOnStartup')
        if 'static func loadBootstrapDaemons(' in text:
            functions += '\n' + method(text, 'loadBootstrapDaemons')
            functions += '\n' + method(text, 'prepareBootstrapDaemon')
        main = cls.base / 'main.swift'
        main.write_text('''import Foundation
import Darwin
let root = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]
let lock = NSLock()
var events: [String] = []
func record(_ text: String) { lock.lock(); events.append(text); lock.unlock() }
func require(_ condition: Bool) { if !condition { exit(1) } }
enum LaunchdPlistPaths {
    static func prepared(_ job: [String: Any], plistPath: String, root: String) -> [String: Any]? {
        var result = job
        result["ProgramArguments"] = [root + "/usr/bin/fixture"]
        return result
    }
}
func loadServices(_ paths: [String], load: Bool, override: Bool) throws -> [String: Any] {
    require(load && !override)
    let attributes = try FileManager.default.attributesOfItem(atPath: paths[0])
    require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
    require((attributes[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid()))
    let job = NSDictionary(contentsOfFile: paths[0])!
    require((job["ProgramArguments"] as? [String]) == [root + "/usr/bin/fixture"])
    let name = URL(fileURLWithPath: paths[0]).lastPathComponent
    record("load:" + name)
    if name == "a-failed.plist" { throw NSError(domain: "fixture", code: 1) }
    return ["verified": true, "unchanged": true]
}
enum GuestAPIError: Error { case operationFailed(String) }
enum GuestIrisinInstaller {
    static func completedBootstrap() throws -> (layout: String, root: String)? {
        record("marker")
        if mode == "invalid" { throw NSError(domain: "fixture", code: 2) }
        if mode == "missing" { return nil }
        return (mode == "rootless" ? "rootless" : "roothide", root)
    }
    static func ensureRootHideLinks(root: String) throws {
        record("repair")
        if mode == "repair-failed" { throw NSError(domain: "fixture", code: 3) }
    }
    static func repairFirmwareRecord() throws -> [String: Any] {
        record("firmware")
        if mode == "firmware-failed" { throw NSError(domain: "fixture", code: 4) }
        return [:]
    }
    static func physicalChildDirectoryExists(root: String, relative: String) throws -> Bool {
        var path = root
        for part in relative.split(separator: "/") {
            path += "/" + part
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw NSError(domain: "fixture", code: 5) }
        }
        return true
    }
''' + functions + '''
}
let directory = URL(fileURLWithPath: root).appendingPathComponent("Library/LaunchDaemons")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for name in ["a-failed.plist", "b-good.plist", "c-existing.plist"] {
    let file = directory.appendingPathComponent(name)
    try PropertyListSerialization.data(fromPropertyList: ["Label": name, "ProgramArguments": ["/usr/bin/fixture"]], format: .xml, options: 0).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
}
try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("d-link.plist"), withDestinationURL: directory.appendingPathComponent("b-good.plist"))
try FileManager.default.createDirectory(at: directory.appendingPathComponent("e-directory.plist"), withIntermediateDirectories: false)
try Data("invalid plist".utf8).write(to: directory.appendingPathComponent("f-invalid.plist"))
try Data(repeating: 32, count: (1 << 20) + 1).write(to: directory.appendingPathComponent("g-oversized.plist"))
if mode == "linked-directory" {
    let library = directory.deletingLastPathComponent()
    try FileManager.default.moveItem(at: library, to: URL(fileURLWithPath: root + "/outside"))
    try FileManager.default.createSymbolicLink(at: library, withDestinationURL: URL(fileURLWithPath: root + "/outside"))
}
GuestIrisinInstaller.refreshBootstrapOnStartup()
Thread.sleep(forTimeInterval: 0.3)
lock.lock(); let actual = events; lock.unlock()
let data = try JSONSerialization.data(withJSONObject: actual)
print(String(data: data, encoding: .utf8)!)
''')
        cls.binary = cls.base / 'startup'
        result = subprocess.run(['swiftc', '-module-cache-path', str(cls.base / 'modules'), str(main), '-o', str(cls.binary)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_case(self, mode):
        import json
        with tempfile.TemporaryDirectory(dir=self.base) as root:
            result = subprocess.run([str(self.binary), root, mode], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def test_completed_roothide_loads_services_after_repair_and_continues_after_failure(self):
        self.assertEqual(self.run_case('installed'), ['marker', 'repair', 'firmware',
            'load:a-failed.plist', 'load:b-good.plist', 'load:c-existing.plist'])

    def test_missing_invalid_and_repair_failure_never_load_services(self):
        for mode, events in [('missing', ['marker']), ('invalid', ['marker']),
                             ('repair-failed', ['marker', 'repair'])]:
            with self.subTest(mode=mode):
                self.assertEqual(self.run_case(mode), events)

    def test_firmware_failure_does_not_disable_bootstrap_service_recovery(self):
        self.assertEqual(self.run_case('firmware-failed'), ['marker', 'repair', 'firmware',
            'load:a-failed.plist', 'load:b-good.plist', 'load:c-existing.plist'])

    def test_rootless_and_linked_launchdaemon_directory_are_not_activated(self):
        self.assertEqual(self.run_case('rootless'), ['marker', 'firmware'])
        self.assertEqual(self.run_case('linked-directory'), ['marker', 'repair', 'firmware'])


if __name__ == '__main__':
    unittest.main()

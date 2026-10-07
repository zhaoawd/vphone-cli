from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
(r/'tests/VPhoneLaunchpadKitTests/BindingPersistenceTests.swift').write_text('''import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

struct BindingPersistenceTests {
    @Test func firstBindingRequiresBackupAndPreservesOriginalConfigAndUnknownOrigins() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundle = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)
        let path = VPhoneLaunchpadMachinePath(libraryRoot: temp.canonicalPath, name: "vm")
        let config = try Data(contentsOf: bundle.configURL)
        #expect(throws: (any Error).self) { try VPhoneLaunchpadMachineBinding.persistHost("2.6.1", machine: path, expected: nil) }
        #expect(VPhoneLaunchpadMachineBinding.load(path) == .missing)
        let backup = temp.url.appendingPathComponent("backup")
        try VPhoneLaunchpadMachineBinding.persistHost("2.6.1", machine: path, expected: nil, firstMigrationBackup: backup)
        #expect(try Data(contentsOf: backup.appendingPathComponent("config.plist")) == config)
        #expect(try Data(contentsOf: bundle.configURL) == config)
        let saved = try #require(try VPhoneLaunchpadMachineBinding.snapshot(path))
        #expect(saved.binding.bundle == "2.6.1")
        #expect(saved.binding.guestEnvironment == nil)
        #expect(saved.binding.kernel == nil)
        #expect(saved.binding.bootChain == nil)
    }

    @Test func hostRebindingPreservesComponentOriginsAndRefusesStaleSnapshot() throws {
        let temp = try LaunchpadTemporaryDirectory()
        _ = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)
        let path = VPhoneLaunchpadMachinePath(libraryRoot: temp.canonicalPath, name: "vm")
        let original = try VPhoneLaunchpadMachineBinding(bundle: "2.6.1", guestEnvironment: "2.5.9", kernel: "2.6.0", bootChain: "2.2.3")
        try JSONEncoder().encode(original).write(to: path.url.appendingPathComponent("launchpad.json"))
        let before = try #require(try VPhoneLaunchpadMachineBinding.snapshot(path))
        try VPhoneLaunchpadMachineBinding.persistHost("2.6.2", machine: path, expected: before)
        let saved = try #require(try VPhoneLaunchpadMachineBinding.snapshot(path)).binding
        #expect(saved == original.replacingHost(with: "2.6.2"))
        #expect(throws: (any Error).self) { try VPhoneLaunchpadMachineBinding.persistHost("2.6.3", machine: path, expected: before) }
        #expect(try VPhoneLaunchpadMachineBinding.snapshot(path)?.binding == saved)
    }
}
'''.replace('#expect(saved == original.replacingHost','#expect(saved == (try original.replacingHost').replace('with: "2.6.2"))','with: "2.6.2")))'))
(r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadBindingPersistence.swift').write_text('''import Foundation
extension VPhoneLaunchpadMachineBinding {
    public static func persistHost(_ version: String, machine: VPhoneLaunchpadMachinePath,
                                  expected: Snapshot?, firstMigrationBackup: URL? = nil) throws {
        throw VPhoneLaunchpadError("Host binding persistence not implemented")
    }
}
''')

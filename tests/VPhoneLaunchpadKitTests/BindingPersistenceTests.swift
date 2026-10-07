import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

struct BindingPersistenceTests {
    @Test func firstBindingRequiresBackupAndPreservesOriginalConfigAndUnknownOrigins() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundle = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)
        let path = VPhoneLaunchpadMachinePath(libraryRoot: temp.canonicalPath, name: "vm")
        try Data("stopped disk".utf8).write(to: bundle.url.appendingPathComponent(bundle.manifest.diskImage))
        let config = try Data(contentsOf: bundle.configURL)
        #expect(throws: (any Error).self) { try VPhoneMachineBinding.persistHost("2.6.1", machine: path.url, expected: nil) }
        #expect(VPhoneLaunchpadMachineBinding.load(path) == .missing)
        let backup = temp.url.appendingPathComponent("backup")
        try VPhoneMachineBinding.persistHost("2.6.1", machine: path.url, expected: nil, firstMigrationBackup: backup)
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
        let bundle = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)
        try Data("stopped disk".utf8).write(to: bundle.url.appendingPathComponent(bundle.manifest.diskImage))
        let path = VPhoneLaunchpadMachinePath(libraryRoot: temp.canonicalPath, name: "vm")
        let original = try VPhoneLaunchpadMachineBinding(bundle: "2.6.1", guestEnvironment: "2.5.9", kernel: "2.6.0", bootChain: "2.2.3")
        try JSONEncoder().encode(original).write(to: path.url.appendingPathComponent("launchpad.json"))
        let before = try #require(try VPhoneLaunchpadMachineBinding.snapshot(path))
        try VPhoneMachineBinding.persistHost("2.6.2", machine: path.url, expected: before)
        let saved = try #require(try VPhoneLaunchpadMachineBinding.snapshot(path)).binding
        #expect(saved == (try original.replacingHost(with: "2.6.2")))
        #expect(throws: (any Error).self) { try VPhoneMachineBinding.persistHost("2.6.3", machine: path.url, expected: before) }
        #expect(try VPhoneLaunchpadMachineBinding.snapshot(path)?.binding == saved)
    }
    @Test func cloneRenameAndExportPreserveAllRecordedOrigins() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundle = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)
        let library = VPhoneLibrary(root: temp.url)
        let binding = try VPhoneLaunchpadMachineBinding(bundle: "2.6.1", guestEnvironment: "2.5.9", kernel: "2.6.0", bootChain: "2.2.3")
        let bytes = try JSONEncoder().encode(binding)
        try bytes.write(to: bundle.url.appendingPathComponent("launchpad.json"))
        let cloned = try VPhoneBundleOps.clone(bundleNamed: "vm", to: "copy", in: library)
        #expect(try Data(contentsOf: cloned.url.appendingPathComponent("launchpad.json")) == bytes)
        let renamed = try VPhoneBundleOps.rename(bundleNamed: "copy", to: "renamed", in: library)
        #expect(try Data(contentsOf: renamed.url.appendingPathComponent("launchpad.json")) == bytes)
        let archive = temp.url.appendingPathComponent("export.tar.zst")
        _ = try VPhoneBundleOps.export(bundleNamed: "renamed", to: archive, includeIPSW: false, in: library)
        let imported = try VPhoneBundleOps.importArchive(from: archive, name: "imported", in: library)
        #expect(try Data(contentsOf: imported.url.appendingPathComponent("launchpad.json")) == bytes)
    }

    @Test func legacyBindingRefusesOpenDiskBeforeBackupOrPublication() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundle = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)
        let disk = bundle.url.appendingPathComponent(bundle.manifest.diskImage)
        try Data("disk in use".utf8).write(to: disk)
        let held = try FileHandle(forReadingFrom: disk)
        defer { try? held.close() }
        let backup = temp.url.appendingPathComponent("backup")
        #expect(throws: (any Error).self) { try VPhoneMachineBinding.persistHost("2.6.1", machine: bundle.url, expected: nil, firstMigrationBackup: backup) }
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("launchpad.json").path))
        withExtendedLifetime(held) {}
    }

}

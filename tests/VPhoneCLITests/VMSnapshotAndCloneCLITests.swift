import ArgumentParser
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

struct VMSnapshotAndCloneCLITests {
    @Test func cloneCommandDefaultsToPreservingIdentityAndSupportsNewIdentityFlag() throws {
        let defaultClone = try VPhoneVMCloneCommand.parse(["src", "dst", "--library-root", "/tmp/lib"])
        #expect(defaultClone.name == "src")
        #expect(defaultClone.newName == "dst")
        #expect(defaultClone.newIdentity == false)

        let newIdentityClone = try VPhoneVMCloneCommand.parse(["src", "dst", "--new-identity", "--library-root", "/tmp/lib"])
        #expect(newIdentityClone.newIdentity == true)
        #expect(VPhoneVMCloneCommand.configuration.discussion.contains("SEPStorage"))
        #expect(VPhoneVMCloneCommand.configuration.discussion.contains("Data volume keys"))
    }

    @Test func snapshotSubcommandsAreRegisteredAndExecuteEndToEnd() throws {
        #expect(try VPhoneCLI.parseAsRoot(["vm", "snapshot", "create", "vm", "snap", "--note", "note", "--library-root", "/tmp/lib"]) is VPhoneVMSnapshotCreateCommand)
        #expect(try VPhoneCLI.parseAsRoot(["vm", "snapshot", "list", "vm", "--json", "--library-root", "/tmp/lib"]) is VPhoneVMSnapshotListCommand)
        #expect(try VPhoneCLI.parseAsRoot(["vm", "snapshot", "revert", "vm", "snap", "--force", "--library-root", "/tmp/lib"]) is VPhoneVMSnapshotRevertCommand)
        #expect(try VPhoneCLI.parseAsRoot(["vm", "snapshot", "delete", "vm", "snap", "--force", "--library-root", "/tmp/lib"]) is VPhoneVMSnapshotDeleteCommand)

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cli-snap-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let lib = VPhoneLibrary(root: root)
        let bundle = try VPhoneBundleOps.create(
            .init(name: "vm", cpuCount: 2, memoryMB: 1024, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: lib
        )
        try Data([1, 2, 3]).write(to: bundle.url.appendingPathComponent("Disk.img"))
        try Data([4, 5, 6]).write(to: bundle.url.appendingPathComponent("SEPStorage"))
        try Data([7, 8, 9]).write(to: bundle.url.appendingPathComponent("nvram.bin"))

        let createCmd = try VPhoneVMSnapshotCreateCommand.parse([
            "vm", "clean", "--note", "before test", "--library-root", root.path
        ])
        try createCmd.run()
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["clean"])

        try Data([9, 9]).write(to: bundle.url.appendingPathComponent("Disk.img"))
        let revertCmd = try VPhoneVMSnapshotRevertCommand.parse([
            "vm", "clean", "--force", "--library-root", root.path
        ])
        try revertCmd.run()
        #expect(try Data(contentsOf: bundle.url.appendingPathComponent("Disk.img")) == Data([1, 2, 3]))

        let cloneCmd = try VPhoneVMCloneCommand.parse([
            "vm", "vm-clone", "--new-identity", "--library-root", root.path
        ])
        try cloneCmd.run()
        let cloned = try lib.bundle(named: "vm-clone")
        #expect(cloned.manifest.machineIdentifier.isEmpty)
        #expect(try VPhoneMachineSnapshots.list(of: cloned).isEmpty)

        let deleteCmd = try VPhoneVMSnapshotDeleteCommand.parse([
            "vm", "clean", "--force", "--library-root", root.path
        ])
        try deleteCmd.run()
        #expect(try VPhoneMachineSnapshots.list(of: bundle).isEmpty)
    }
}

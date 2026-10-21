import ArgumentParser
import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

struct VMRebaseCLITests {
    @Test func commandRegistrationAndMutuallyExclusiveArguments() throws {
        #expect(try VPhoneCLI.parseAsRoot(["vm", "rebase", "a", "--onto", "b", "--dry-run"]) is VPhoneVMRebaseCommand)
        #expect(try VPhoneCLI.parseAsRoot(["vm", "rebase", "a", "--recover"]) is VPhoneVMRebaseCommand)
        for arguments in [["a"], ["a", "--recover", "--onto", "b"], ["a", "--recover", "--dry-run"],
                          ["../a", "--onto", "b"], ["a", "--onto", "../b"]] {
            #expect(throws: (any Error).self) { try VPhoneVMRebaseCommand.parse(arguments) }
        }
    }

    @Test func actualCommandKeepsLogicalBytesAndReportsAlreadySharedUnits() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rebase-cli-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let library = VPhoneLibrary(root: root)
        var bundles: [VPhoneBundle] = []
        for name in ["target", "base"] {
            bundles.append(try VPhoneBundleOps.create(.init(name: name, cpuCount: 2, memoryMB: 1024,
                diskSizeGB: 1, romSource: rom, sepromSource: rom), in: library))
        }
        let target = bundles[0].url.appendingPathComponent("Disk.img")
        let base = bundles[1].url.appendingPathComponent("Disk.img")
        let bytes = Data(repeating: 0x41, count: 1 << 20)
        try bytes.write(to: target)
        try fm.removeItem(at: base)
        try #require(clonefile(target.path, base.path, 0) == 0)
        let preview = try VPhoneVMRebaseCommand.parse(["target", "--onto", "base", "--dry-run", "--library-root", root.path])
        try preview.run()
        let report = try VPhoneDiskRebase.plan(bundles[0], onto: bundles[1])
        #expect(report.newlySharedBytes == 0)
        #expect(report.alreadySharedBytes > 0)
        #expect(VPhoneVMRebaseCommand.describe(report, base: "base", dryRun: true).contains { $0.contains("already shared") })
        try VPhoneVMRebaseCommand.parse(["target", "--onto", "base", "--library-root", root.path]).run()
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try Data(contentsOf: base) == bytes)
        try VPhoneVMRebaseCommand.parse(["target", "--recover", "--library-root", root.path]).run()
        let otherRoot = root.appendingPathComponent("other-library")
        try fm.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        let foreign = try VPhoneBundleOps.create(.init(name: "foreign", cpuCount: 2, memoryMB: 1024,
            diskSizeGB: 1, romSource: rom, sepromSource: rom), in: VPhoneLibrary(root: otherRoot))
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: foreign.url)
        #expect(throws: ValidationError.self) {
            try VPhoneVMRebaseCommand.parse(["target", "--onto", "alias", "--dry-run", "--library-root", root.path]).run()
        }
    }
}

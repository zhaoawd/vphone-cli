import ArgumentParser
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

@Suite struct FWReceiptsCLITests {
    @Test func parsesReadAndRequiresCompleteUndoPreviewSelection() throws {
        #expect(try VPhoneCLI.parseAsRoot(["fw", "receipts", "sample", "--json"]) is VPhoneFWReceiptsCommand)
        let generation = String(repeating: "a", count: 64)
        _ = try VPhoneCLI.parseAsRoot(["fw", "receipts", "sample", "--undo-component", "avpbooter",
            "--generation", generation, "--declaration", "avpbooter-boot-dgst_bypass", "--json"])
        for extra in [["--generation", generation], ["--declaration", "patch"], ["--undo-component", "avpbooter"],
                      ["--undo-component", "avpbooter", "--generation", "bad", "--declaration", "patch"],
                      ["--undo-component", "avpbooter", "--generation", generation, "--declaration", "patch", "patch"]] {
            #expect(throws: (any Error).self) { try VPhoneCLI.parseAsRoot(["fw", "receipts", "sample"] + extra) }
        }
    }

    @Test func missingReceiptRemainsUnknownEvenWithLegacyAppliedIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("PatchReceipt.plist")
        let data = try PropertyListSerialization.data(fromPropertyList:
            ["Parts": ["Guest": ["Patches": ["dyld-boot-iomfb_force_kern"], "Writer": "legacy", "Date": Date()]]],
            format: .xml, options: 0)
        try data.write(to: legacy)
        let result = try VPhoneFWReceiptsCommand.report(in: root)
        #expect(result.state == "unknown" && result.receipts == nil && result.undoPreview == nil)
        #expect(try Data(contentsOf: legacy) == data)
        #expect(throws: (any Error).self) {
            try VPhoneFWReceiptsCommand.report(in: root, component: "Guest", generation: String(repeating: "a", count: 64),
                declarations: ["dyld-boot-iomfb_force_kern"])
        }
    }

    @Test func corruptReceiptFailsThroughActualCLIWithoutChangingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vm = root.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneVirtualMachineManifest(cpuCount: 2, memorySize: 1 << 30, romImages: nil)
            .write(to: vm.appendingPathComponent("config.plist"))
        let file = vm.appendingPathComponent(".firmware-component-receipts.json")
        try Data("broken".utf8).write(to: file)
        var command = try VPhoneCLI.parseAsRoot(["fw", "receipts", "sample", "--library-root", root.path, "--json"])
        #expect(throws: (any Error).self) { try command.run() }
        #expect(try Data(contentsOf: file) == Data("broken".utf8))
    }
}

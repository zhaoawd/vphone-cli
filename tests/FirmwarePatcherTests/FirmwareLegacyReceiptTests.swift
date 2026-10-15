import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareLegacyReceiptTests {
    func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
    @Test func exactLegacyFieldsRemainUnverifiedAndPreserveBytes() throws {
        let bytes = try plist(["Parts": ["kernelcache": ["Patches": ["kernel-base-cs_bypass"],
            "Writer": "restore", "BundleVersion": "2.6.1", "Date": Date(timeIntervalSince1970: 1)],
            "Guest": ["Patches": [], "Writer": "cfw install", "Date": Date(timeIntervalSince1970: 2),
                      "NotApplicable": ["unknown-patch"]],
            "Future": ["Patches": [], "Writer": "future", "Date": Date(timeIntervalSince1970: 3)]]])
        let result = FirmwareLegacyReceipt.importReceipt(bytes)
        #expect(result.raw == bytes)
        #expect(result.status == .imported)
        #expect(result.parts["kernelcache"]?.layer == .kernel)
        #expect(result.parts["Guest"]?.layer == .guestEnvironment)
        #expect(result.parts["Future"]?.layer == nil)
        #expect(result.parts["Guest"]?.notApplicable == ["unknown-patch"])
        #expect(result.parts["kernelcache"]?.notApplicable == [])
        #expect(result.parts["kernelcache"]?.writer == "restore")
        #expect(result.parts["kernelcache"]?.bundleVersion == "2.6.1")
        #expect(result.verifiedDeclarations.isEmpty)
    }
    @Test func missingCorruptUnsupportedAndAmbiguousRemainDistinct() throws {
        #expect(FirmwareLegacyReceipt.importReceipt(nil).status == .missing)
        let corrupt = Data("broken".utf8)
        #expect(FirmwareLegacyReceipt.importReceipt(corrupt).status == .corrupt)
        #expect(FirmwareLegacyReceipt.importReceipt(corrupt).raw == corrupt)
        #expect(FirmwareLegacyReceipt.importReceipt(try plist(["SchemaVersion": 2, "Parts": [:]])).status == .unsupported)
        #expect(FirmwareLegacyReceipt.importReceipt(try plist(["Parts": ["Guest": ["Patches": []]]])).status == .corrupt)
        let duplicate = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Parts</key><dict/><key>Parts</key><dict/></dict></plist>".utf8)
        #expect(FirmwareLegacyReceipt.importReceipt(duplicate).status == .corrupt)
    }
    @Test func legacyPlanEnabledIsSelectionDataOnly() throws {
        let bytes = try plist(["Preset": "standard", "EnabledPatches": ["unknown"], "Parameters": ["value": "x"]])
        let result = FirmwareLegacyReceipt.importPlan(bytes)
        #expect(result.raw == bytes)
        #expect(result.status == .imported)
        #expect(result.plan?.enabledPatches == ["unknown"])
        #expect(result.plan?.patchSets == [])
        #expect(result.plan?.parameters == ["value": "x"])
        #expect(result.verifiedDeclarations.isEmpty)
        #expect(FirmwareLegacyReceipt.importPlan(try plist([:])).status == .corrupt)
    }
}

extension FirmwareLegacyReceiptTests {
    @Test func preparedReceiptIsUnreadableUntilItsJournalCommits() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let t = try FirmwareReceiptPublicationTests().begin(f)
        try FirmwareReceiptPublicationTests().prepare(f, t)
        let prepared = try Data(contentsOf: t.root.appendingPathComponent("component-receipts.json"))
        // A prepared state of .committed is not a committed transaction.
        try prepared.write(to: f.vm.appendingPathComponent(".firmware-component-receipts.json"))
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.readCommitted(in: f.vm) }
        try FileManager.default.removeItem(at: f.vm.appendingPathComponent(".firmware-component-receipts.json"))
        _ = try t.commit()
        let records = try #require(try FirmwareComponentReceipt.readCommitted(in: f.vm))
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.scope == .generatedFirmware })
        var object = try #require(JSONSerialization.jsonObject(with: prepared) as? [String: Any])
        object["transactionID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: object).write(to: f.vm.appendingPathComponent(".firmware-component-receipts.json"))
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.readCommitted(in: f.vm) }
    }
}

extension FirmwareLegacyReceiptTests {
    @Test func diskImportPreservesRawAndDoesNotTreatUnreadableAsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try FirmwareLegacyReceipt.readReceipt(in: root).status == .missing)
        let bytes = Data("corrupt original".utf8)
        let file = root.appendingPathComponent("PatchReceipt.plist")
        try bytes.write(to: file)
        let imported = try FirmwareLegacyReceipt.readReceipt(in: root)
        #expect(imported.status == .corrupt && imported.raw == bytes)
        #expect(try Data(contentsOf: file) == bytes)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("absent"))
        #expect(throws: (any Error).self) { try FirmwareLegacyReceipt.readReceipt(in: root) }
    }
}

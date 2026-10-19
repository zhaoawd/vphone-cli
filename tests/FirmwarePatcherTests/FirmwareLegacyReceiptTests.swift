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
    @Test func changedDesiredPlanPreservesEvidenceOfActualCommittedPlan() throws {
        let f = try FirmwareComponentUndoTests().committed()
        let old = try #require(try FirmwareComponentReceipt.readCommitted(in: f.vm))
        guard case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: f.vm) else { throw POSIXError(.EINVAL) }
        let plan = try FirmwarePipeline(vmDirectory: f.vm, variant: .dev, verbose: false).resolvedPlan()
        #expect(plan != f.plan)
        let pending = try FirmwareDesiredPlanStore.prepare(in: f.vm, plan: plan, generation: f.generation)
        _ = try FirmwareDesiredPlanStore.publish(pending, expectedSHA256: desired.sha256)
        #expect(try FirmwareComponentReceipt.readCommitted(in: f.vm) == old)
        let snapshot = try FirmwareComponentUndo.load(in: f.vm, component: "avpbooter", generationID: f.generation.id)
        #expect(try snapshot.restoring(declarations: Set(snapshot.receipt.effects.map(\.declarationID))).data == Data([0]))
    }

    @Test(arguments: ["missing", "corrupt"])
    func absentOrCorruptArchivedProducerReportCannotAuthorizeReceipt(_ fault: String) throws {
        let f = try FirmwareComponentUndoTests().committed()
        let history = f.vm.appendingPathComponent(".firmware-history")
        let archive = try #require(FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).first)
        let report = archive.appendingPathComponent("report.json")
        if fault == "missing" { try FileManager.default.removeItem(at: report) }
        else { try Data("broken".utf8).write(to: report) }
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.readCommitted(in: f.vm) }
    }

    @Test func receiptCannotInventUndoOriginalAbsentFromSavedProducerReport() throws {
        let f = try FirmwareComponentUndoTests().committed()
        let live = f.vm.appendingPathComponent(".firmware-component-receipts.json")
        var publication = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: live)) as? [String: Any])
        let transactionID = try #require(publication["transactionID"] as? String)
        var records = try #require(publication["records"] as? [[String: Any]])
        var effects = try #require(records[0]["effects"] as? [[String: Any]])
        var record = try #require(effects[0]["record"] as? [String: Any])
        record["originalBytes"] = Data([9]).base64EncodedString()
        effects[0]["record"] = record; records[0]["effects"] = effects; publication["records"] = records
        let bytes = try JSONSerialization.data(withJSONObject: publication, options: .sortedKeys)
        let archive = f.vm.appendingPathComponent(".firmware-history/" + transactionID)
        try bytes.write(to: live)
        try bytes.write(to: archive.appendingPathComponent("component-receipts.json"))
        let journalFile = archive.appendingPathComponent("journal.json")
        var journal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalFile)) as? [String: Any])
        let digest = DeclarationExecutionEvidence.digest(bytes)
        journal["componentReceiptsSHA256"] = digest
        var metadata = try #require(journal["metadata"] as? [[String: Any]])
        let index = try #require(metadata.firstIndex { $0["name"] as? String == ".firmware-component-receipts.json" })
        metadata[index]["output"] = digest; journal["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: journal).write(to: journalFile)
        // Receipt hashes and current output still agree. The immutable producer
        // report is the remaining evidence that this claimed original is false.
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.readCommitted(in: f.vm) }
        #expect(try Data(contentsOf: f.file) == Data([1]))
    }

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

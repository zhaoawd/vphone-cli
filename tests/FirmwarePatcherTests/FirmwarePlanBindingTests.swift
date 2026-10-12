import Darwin
import Foundation
import Testing
import Virtualization
@testable import FirmwarePatcher

@Suite struct FirmwarePlanBindingTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var file: URL { root.appendingPathComponent("AVPBooter.input.bin") }
        var journal: URL { root.appendingPathComponent(".firmware-transaction/journal.json") }
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: file)
            try Data("disk".utf8).write(to: root.appendingPathComponent("Disk.img"))
            try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": VZMacMachineIdentifier().dataRepresentation, "diskImage": "Disk.img"], format: .xml, options: 0)
                .write(to: root.appendingPathComponent("config.plist"))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func begin(inject: @escaping (FirmwareTransaction.Event) throws -> Void = { _ in }) throws -> FirmwareTransaction {
            let plan = try VariantPlanResolver.resolve(variant: .regular, gates: VariantPlanTests.snapshots(.regular)[0])
            return try FirmwareTransaction(vmDirectory: root, inputs: [file], options: ["variant": "regular"],
                plan: plan, versionInputs: FirmwareVersionInputs.read(in: root), inject: inject, mounts: { _, _ in })
        }
        func object() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        }
        func write(_ object: [String: Any]) throws { try JSONSerialization.data(withJSONObject: object).write(to: journal) }
        func recover() throws -> URL? { try FirmwareTransaction.recover(vmDirectory: root, mounts: { _, _ in }) }
    }

    @Test func newPlanJournalBindsContextAndUsesVersionTwo() throws {
        let f = try Fixture(); _ = try f.begin()
        let object = try f.object()
        #expect(object["version"] as? Int == 2)
        let binding = try #require(object["planBinding"] as? [String: Any])
        #expect(binding["schemaVersion"] as? Int == 2)
        #expect((binding["planSHA256"] as? String)?.count == 64)
        #expect((binding["contextSHA256"] as? String)?.count == 64)
        let payload = try #require(binding["payload"] as? [String: Any])
        #expect(payload["upstreamTarget"] as? String == "2d21d21fbdd4f51f013616273ceda9b35a3e0789")
        #expect((payload["catalogSHA256"] as? String)?.count == 64)
        #expect(payload["stableIdentity"] != nil)
        #expect(payload["configSHA256"] == nil)
        #expect(try f.recover() != nil)
    }

    @Test(arguments: ["plan", "options", "original"])
    func editedRecordCannotAuthorizeRecovery(_ field: String) throws {
        let f = try Fixture(); _ = try f.begin(); var object = try f.object()
        if field == "plan" {
            var plan = try #require(object["plan"] as? [String: Any]); plan["variant"] = "jb"; object["plan"] = plan
        } else if field == "options" {
            object["options"] = ["variant": "jb"]
        } else {
            var entries = try #require(object["entries"] as? [[String: Any]])
            entries[0]["original"] = String(repeating: "0", count: 64); object["entries"] = entries
        }
        try f.write(object)
        #expect(throws: (any Error).self) { try f.recover() }
        #expect(try Data(contentsOf: f.file) == Data("original".utf8))
        #expect(FileManager.default.fileExists(atPath: f.journal.path))
    }

    @Test func missingBindingIsNotTreatedAsLegacyVersionTwo() throws {
        let f = try Fixture(); _ = try f.begin(); var object = try f.object()
        object["version"] = 2; object.removeValue(forKey: "planBinding"); try f.write(object)
        #expect(throws: (any Error).self) { try f.recover() }
    }

    @Test func changedVMConfigRefusesCommitBeforePublication() throws {
        let f = try Fixture()
        let transaction = try f.begin { event in
            if event == .beforeReady {
                try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": Data("machine-b".utf8)], format: .xml, options: 0)
                    .write(to: f.root.appendingPathComponent("config.plist"))
            }
        }
        try Data("patched".utf8).write(to: transaction.stage.appendingPathComponent("AVPBooter.input.bin"))
        #expect(throws: (any Error).self) { try transaction.commit() }
        #expect(try Data(contentsOf: f.file) == Data("original".utf8))
    }

    @Test func explicitLegacyRecoveryDoesNotUpgradeTheRecord() throws {
        let f = try Fixture(); _ = try f.begin(); var object = try f.object()
        object["version"] = 1; object.removeValue(forKey: "planBinding"); try f.write(object)
        let archive = try #require(try f.recover())
        let recovered = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: archive.appendingPathComponent("journal.json"))) as? [String: Any])
        #expect(recovered["version"] as? Int == 1)
        #expect(recovered["planBinding"] == nil)
    }
    @Test func missingCorruptUnsupportedAndUnreadableAreDistinct() throws {
        let f = try Fixture()
        #expect(throws: FirmwareTransaction.RecordFailure.missing) { try FirmwareTransaction.readJournal(at: f.journal) }
        _ = try f.begin()
        let original = try Data(contentsOf: f.journal)
        try Data("broken JSON".utf8).write(to: f.journal)
        #expect(throws: FirmwareTransaction.RecordFailure.corrupt) { try FirmwareTransaction.readJournal(at: f.journal) }
        try original.write(to: f.journal)
        var object = try f.object(); object["version"] = 999; try f.write(object)
        #expect(throws: FirmwareTransaction.RecordFailure.unsupportedSchema(999)) { try FirmwareTransaction.readJournal(at: f.journal) }
        try original.write(to: f.journal)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.journal.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.journal.path) }
        #expect(throws: FirmwareTransaction.RecordFailure.unreadable(EACCES)) { try FirmwareTransaction.readJournal(at: f.journal) }
    }

    @Test(arguments: ["schemaVersion", "planSHA256", "contextSHA256"])
    func unsupportedOrChangedBindingIsRefused(_ field: String) throws {
        let f = try Fixture(); _ = try f.begin(); var object = try f.object()
        var binding = try #require(object["planBinding"] as? [String: Any])
        if field == "schemaVersion" { binding[field] = 999 }
        else { binding[field] = String(repeating: "0", count: 64) }
        object["planBinding"] = binding; try f.write(object)
        #expect(throws: (any Error).self) { try f.recover() }
        #expect(try Data(contentsOf: f.file) == Data("original".utf8))
    }

    @Test func replacementDirectoryAtSamePathCannotReuseTheBinding() throws {
        let f = try Fixture(); _ = try f.begin()
        let copy = f.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let kept = f.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: kept); try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: f.root, to: copy)
        try FileManager.default.moveItem(at: f.root, to: kept)
        try FileManager.default.moveItem(at: copy, to: f.root)
        #expect(throws: (any Error).self) { try f.recover() }
        #expect(try Data(contentsOf: f.file) == Data("original".utf8))
    }

}

extension FirmwarePlanBindingTests {
    @Test func schemaOneBindingRetainsRecoveryOnlySemantics() throws {
        let f = try Fixture(); _ = try f.begin()
        var object = try f.object()
        var binding = try #require(object["planBinding"] as? [String: Any])
        var payload = try #require(binding["payload"] as? [String: Any])
        payload.removeValue(forKey: "stableIdentity")
        payload.removeValue(forKey: "generationID")
        var info = stat()
        #expect(lstat(f.root.path, &info) == 0)
        payload["vmDirectoryId"] = "\(info.st_dev):\(info.st_ino)"
        payload["configSHA256"] = DeclarationExecutionEvidence.digest(try Data(contentsOf: f.root.appendingPathComponent("config.plist")))
        binding["schemaVersion"] = 1
        binding["payload"] = payload
        let decoded = try JSONDecoder().decode(FirmwarePlanBinding.Payload.self, from: JSONSerialization.data(withJSONObject: payload))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        binding["contextSHA256"] = DeclarationExecutionEvidence.digest(try encoder.encode(decoded))
        object["planBinding"] = binding
        try f.write(object)
        let journal = try FirmwareTransaction.readJournal(at: f.journal)
        try journal.planBinding?.validate(journal: journal, directory: f.root, currentCatalog: false)
        #expect(throws: (any Error).self) {
            try journal.planBinding?.validate(journal: journal, directory: f.root, currentCatalog: true)
        }
        let archived = try #require(try f.recover())
        let recovered = try FirmwareTransaction.readJournal(at: archived.appendingPathComponent("journal.json"))
        #expect(recovered.planBinding?.schemaVersion == 1)
        #expect(recovered.planBinding?.payload.stableIdentity == nil)
        #expect(recovered.planBinding?.contextSHA256 == binding["contextSHA256"] as? String)
    }
}

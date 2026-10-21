import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareDesiredPlanStoreTests {
    @Test func corruptDesiredDoesNotDefaultBeforeExecution() throws {
        let f = try FirmwarePlanBindingTests.Fixture()
        try Data("broken JSON".utf8).write(to: f.root.appendingPathComponent(".firmware-desired-plan.json"))
        do {
            _ = try FirmwarePipeline(vmDirectory: f.root, verbose: false).patchAll()
            Issue.record("corrupt desired plan accepted")
        } catch {
            #expect(String(describing: error).contains("desired plan"))
        }
    }
}

import Darwin
import VPhoneCore

extension FirmwareDesiredPlanStoreTests {
    typealias Store = FirmwareDesiredPlanStore
    @Test func bytePreservingRebaseDoesNotReauthorizeTheOldDiskInodeBinding() throws {
        let (f, prepared) = try ready()
        _ = try Store.publish(prepared, expectedSHA256: nil)
        guard case .ready = try Store.read(in: f.vm) else { Issue.record("plan was not ready before rebase"); return }
        let desired = try Data(contentsOf: f.vm.appendingPathComponent(Store.filename))
        let disk = try Data(contentsOf: f.disk)
        let baseURL = f.root.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: f.disk, to: baseURL.appendingPathComponent("Disk.img"))
        let manifest = VPhoneVirtualMachineManifest(cpuCount: 2, memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "rom.bin", avpSEPBooter: "sep.bin"))
        try VPhoneDiskRebase.rebase(VPhoneBundle(url: f.vm, manifest: manifest),
            onto: VPhoneBundle(url: baseURL, manifest: manifest))
        #expect(try Data(contentsOf: f.disk) == disk)
        #expect(try Data(contentsOf: f.vm.appendingPathComponent(Store.filename)) == desired)
        #expect(throws: Store.Failure.identityMismatch) { try Store.read(in: f.vm) }
    }
    @Test func missingIsDistinctFromPermissionDenied() throws {
        let f = try FirmwarePlanBindingTests.Fixture()
        guard case .missing = try Store.read(in: f.root) else { Issue.record("not missing"); return }
        let file = f.root.appendingPathComponent(Store.filename)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { chmod(file.path, 0o600) }
        #expect(throws: Store.Failure.unreadable(EACCES)) { try Store.read(in: f.root) }
    }
    @Test func unsupportedSchemaDoesNotDefault() throws {
        let f = try FirmwarePlanBindingTests.Fixture()
        try Data("{\"schemaVersion\":999}".utf8).write(to: f.root.appendingPathComponent(Store.filename))
        #expect(throws: Store.Failure.unsupportedSchema(999)) { try Store.read(in: f.root) }
    }
    @Test func journalCannotAuthorizeNewExecution() throws {
        let f = try FirmwarePlanBindingTests.Fixture(); _ = try f.begin()
        guard case .missing = try Store.read(in: f.root) else { Issue.record("journal used as desired"); return }
        _ = try f.recover()
        #expect(throws: Store.Failure.missing) { try FirmwarePipeline(vmDirectory: f.root, verbose: false).patchAll() }
    }
    func ready() throws -> (FirmwareGenerationTests.Fixture, Store.Prepared) {
        let f = try FirmwareGenerationTests.Fixture()
        let generation = try f.publish()
        let plan = try FirmwarePipeline(vmDirectory: f.vm, verbose: false).resolvedPlan()
        return (f, try Store.prepare(in: f.vm, plan: plan, generation: generation))
    }
    @Test func legacyImportPreservesOriginal() throws {
        let (f, prepared) = try ready()
        let file = f.vm.appendingPathComponent("PatchSelection.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["Preset": "standard", "AllowedPatches": [], "BlockedPatches": []], format: .xml, options: 0)
        try original.write(to: file)
        guard case .legacy(let preview) = try Store.read(in: f.vm) else { Issue.record("not legacy"); return }
        let generation = try FirmwareGeneration.loadVerified(in: f.vm, id: prepared.record.generationID)
        let p = try Store.prepare(in: f.vm, plan: FirmwarePipeline(vmDirectory: f.vm, verbose: false).resolvedPlan(), generation: generation)
        _ = try Store.publish(p, expectedSHA256: nil)
        #expect(try Data(contentsOf: file) == original)
        #expect(try Data(contentsOf: f.vm.appendingPathComponent(".firmware-desired-backup-" + preview.sourceSHA256)) == original)
    }
    @Test func nilDoesNotIgnoreConcurrentChange() throws {
        let (f, p) = try ready()
        _ = try Store.publish(p, expectedSHA256: nil)
        #expect(throws: Store.Failure.changedSincePreview) { try Store.publish(p, expectedSHA256: nil) }
        guard case .ready(let record) = try Store.read(in: f.vm) else { Issue.record("not ready"); return }
        let next = try Store.prepare(in: f.vm, plan: p.record.plan, generation: FirmwareGeneration.loadVerified(in: f.vm, id: p.record.generationID))
        #expect(throws: Store.Failure.changedSincePreview) { try Store.publish(next, expectedSHA256: nil) }
        _ = try Store.publish(next, expectedSHA256: record.sha256)
        let backup = f.vm.appendingPathComponent(".firmware-desired-backup-" + (try record.sha256))
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
    @Test(arguments: Store.Event.allCases)
    func publishFailureRequiresReadback(_ point: Store.Event) throws {
        let (f, initial) = try ready()
        let old = try Store.publish(initial, expectedSHA256: nil)
        let generation = try FirmwareGeneration.loadVerified(in: f.vm, id: old.generationID)
        let newPlan = try FirmwarePipeline(vmDirectory: f.vm, variant: .dev, verbose: false).resolvedPlan()
        let p = try Store.prepare(in: f.vm, plan: newPlan, generation: generation)
        struct Injected: Error {}
        #expect(throws: (any Error).self) {
            try Store.publish(p, expectedSHA256: old.sha256) { if $0 == point { throw Injected() } }
        }
        if FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(Store.pendingFilename).path) {
            #expect(throws: Store.Failure.publicationUncertain) { try Store.publish(p, expectedSHA256: old.sha256) }
            _ = try Store.readback(in: f.vm)
        }
        guard case .ready(let observed) = try Store.read(in: f.vm) else { Issue.record("lost desired plan"); return }
        if point == .afterRename || point == .directorySync || point == .cleanupSync {
            #expect(observed == p.record)
        } else {
            #expect(observed == old)
        }
        if point != .beforeBackup {
            let backup = f.vm.appendingPathComponent(".firmware-desired-backup-" + (try old.sha256))
            #expect(try JSONDecoder().decode(Store.Record.self, from: Data(contentsOf: backup)) == old)
        }
    }
}

extension FirmwareDesiredPlanStoreTests {
    @Test func decodedManifestAndLegacyRulesAreNotAuthority() throws {
        let (f, p) = try ready()
        let generation = try FirmwareGeneration.loadVerified(in: f.vm, id: p.record.generationID)
        let forged = FirmwareGeneration.Manifest(schemaVersion: 99, id: generation.id, content: generation.content)
        #expect(throws: Store.Failure.identityMismatch) { try Store.prepare(in: f.vm, plan: p.record.plan, generation: forged) }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(p.record.plan)) as? [String: Any])
        var selected = try #require(object["selected"] as? [[String: Any]])
        selected[0].removeValue(forKey: "recordRules"); object["selected"] = selected
        let old = try JSONDecoder().decode(VariantPlanResolver.VariantPlan.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.selected[0].recordRules == nil)
        #expect(throws: Store.Failure.invalidPlan) { try Store.prepare(in: f.vm, plan: old, generation: generation) }
        #expect(old.selected[0].recordRules == nil)
    }
    @Test func diskReplacementAndGenerationCorruptionRefuseExecution() throws {
        let (f, p) = try ready(); _ = try Store.publish(p, expectedSHA256: nil)
        try FileManager.default.moveItem(at: f.disk, to: f.root.appendingPathComponent("old-disk"))
        try Data("replacement".utf8).write(to: f.disk)
        #expect(throws: Store.Failure.identityMismatch) { try Store.read(in: f.vm) }
        #expect(throws: Store.Failure.identityMismatch) { try FirmwarePipeline(vmDirectory: f.vm).patchAll() }
    }
    @Test func existingBackupNeverOverwritten() throws {
        let (f, p) = try ready(); let record = try Store.publish(p, expectedSHA256: nil)
        let generation = try FirmwareGeneration.loadVerified(in: f.vm, id: record.generationID)
        let next = try Store.prepare(in: f.vm, plan: record.plan, generation: generation)
        let backup = f.vm.appendingPathComponent(".firmware-desired-backup-" + (try record.sha256))
        let evidence = Data("existing evidence".utf8); try evidence.write(to: backup)
        #expect(throws: Store.Failure.backupConflict) { try Store.publish(next, expectedSHA256: record.sha256) }
        #expect(try Data(contentsOf: backup) == evidence)
        guard case .ready(let after) = try Store.read(in: f.vm) else { Issue.record("lost prior plan"); return }
        #expect(after == record)
    }
    @Test(arguments: [Store.Event.afterBackup, .beforeRename])
    func concurrentEditNeverOverwritten(_ event: Store.Event) throws {
        let (f, p) = try ready()
        let concurrent = Data("concurrent desired record".utf8)
        let file = f.vm.appendingPathComponent(Store.filename)
        #expect(throws: (any Error).self) {
            try Store.publish(p, expectedSHA256: nil) { if $0 == event { try concurrent.write(to: file) } }
        }
        #expect(try Data(contentsOf: file) == concurrent)
        #expect(throws: (any Error).self) { try Store.readback(in: f.vm) }
        #expect(try Data(contentsOf: file) == concurrent)
    }
    @Test func pipelineAdapterHoldsVMLockAndPreviewDoesNotPublish() throws {
        let (f, p) = try ready()
        let pipeline = FirmwarePipeline(vmDirectory: f.vm, verbose: false)
        let lock = try VPhoneVMLock(directory: f.vm, operation: VPhoneVMOperation.fwPatch)
        withExtendedLifetime(lock) {
            #expect(throws: (any Error).self) {
                try pipeline.saveDesiredPlan(generationID: p.record.generationID, apply: true, expectedSHA256: nil)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(Store.filename).path))
    }
    @Test func adapterPreviewThenPublishExecutesBoundPreflight() throws {
        let (f, p) = try ready()
        let pipeline = FirmwarePipeline(vmDirectory: f.vm, verbose: false)
        let preview = try pipeline.saveDesiredPlan(generationID: p.record.generationID, apply: false, expectedSHA256: nil)
        #expect(preview.expectedSHA256 == nil)
        #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(Store.filename).path))
        _ = try pipeline.saveDesiredPlan(generationID: p.record.generationID, apply: true, expectedSHA256: nil)
        // Real fixture payload is deliberately not executable firmware; reaching its patch
        // failure with a saved journal proves the production preflight consumed the plan.
        _ = try? pipeline.patchAll()
        let journal = try FirmwareTransaction.readJournal(at: f.vm.appendingPathComponent(".firmware-transaction/journal.json"))
        #expect(journal.options["generationID"] == p.record.generationID)
        #expect(journal.options["desiredSHA256"] == (try preview.record.sha256))
        #expect(journal.plan == preview.record.plan)
        _ = try FirmwarePipeline.recoverFirmware(in: f.vm)
        #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(".firmware-transaction").path))
    }
}

extension FirmwareDesiredPlanStoreTests {
    @Test func changedDesiredRefusesCommitButDoesNotBlockJournalRecovery() throws {
        let (f, p) = try ready(); let record = try Store.publish(p, expectedSHA256: nil)
        let pipeline = FirmwarePipeline(vmDirectory: f.vm, verbose: false)
        let roots = try pipeline.transactionRoots()
        let restore = try #require(roots.first { $0.lastPathComponent.contains("Restore") })
        let transaction = try FirmwareTransaction(vmDirectory: f.vm, inputs: roots,
            options: ["variant": "regular", "generationID": record.generationID, "desiredSHA256": record.sha256],
            plan: record.plan, versionInputs: FirmwareVersionInputs.read(in: restore), mounts: { _, _ in })
        try Data("broken desired".utf8).write(to: f.vm.appendingPathComponent(Store.filename))
        #expect(throws: Store.Failure.corrupt) { try transaction.commit() }
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) != nil)
        #expect(throws: Store.Failure.corrupt) { try pipeline.patchAll() }
    }
    @Test func legacyImportRequiresSourceDigestAtLockedAdapter() throws {
        let (f, p) = try ready()
        let file = f.vm.appendingPathComponent("PatchSelection.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["Preset": "standard", "AllowedPatches": [], "BlockedPatches": ["ibss.serial_label"]], format: .xml, options: 0)
        try original.write(to: file)
        let pipeline = FirmwarePipeline(vmDirectory: f.vm, verbose: false)
        #expect(throws: (any Error).self) {
            try pipeline.saveDesiredPlan(generationID: p.record.generationID, apply: false, expectedSHA256: nil)
        }
        let preview = try pipeline.saveDesiredPlan(generationID: p.record.generationID, apply: false,
            expectedSHA256: nil, importLegacy: true)
        #expect(preview.expectedLegacySHA256 != nil)
        #expect(preview.record.plan.excludedByOptIn.contains { $0.id == "ibss-cfw-serial_label" && $0.reason == "blocked by request" })
        #expect(throws: Store.Failure.changedSincePreview) {
            try pipeline.saveDesiredPlan(generationID: p.record.generationID, apply: true,
                expectedSHA256: nil, importLegacy: true)
        }
        _ = try pipeline.saveDesiredPlan(generationID: p.record.generationID, apply: true,
            expectedSHA256: nil, importLegacy: true, expectedLegacySHA256: preview.expectedLegacySHA256)
        #expect(try Data(contentsOf: file) == original)
    }
}

extension FirmwareDesiredPlanStoreTests {
    @Test func explicitDesiredOverridesReachSavedPlan() throws {
        let (f, p) = try ready()
        let pipeline = FirmwarePipeline(vmDirectory: f.vm, verbose: false)
        #expect(throws: (any Error).self) {
            try pipeline.saveDesiredPlan(generationID: p.record.generationID, apply: false, expectedSHA256: nil,
                select: ["ibss-cfw-serial_label", "ibss-cfw-serial_label"])
        }
        let result = try pipeline.saveDesiredPlan(generationID: p.record.generationID, apply: true,
            expectedSHA256: nil, block: ["ibss-cfw-serial_label"])
        #expect(!result.record.plan.enabledSteps.contains("ibss.IBootPatcher.patchSerialLabels"))
        guard case .ready(let saved) = try Store.read(in: f.vm) else { Issue.record("no saved plan"); return }
        #expect(saved == result.record)
    }
}

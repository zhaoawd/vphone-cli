import Foundation
import Testing
import VPhoneCore
@testable import FirmwarePatcher

@Suite struct FirmwareReceiptPublicationTests {
    @Test func missingRecordCannotPublishReceipt() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let t = try begin(f)
        // A complete report without any final-output receipts used to publish.
        try t.saveReport(RequiredDeclarationEvidenceTests.complete(f.plan))
        #expect(throws: (any Error).self) { try t.commit() }
        #expect(t.journalSnapshot.phase != .committed)
        #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(".firmware-component-receipts.json").path))
    }

    func begin(_ f: FirmwareComponentReceiptTests.Fixture,
               inject: @escaping (FirmwareTransaction.Event) throws -> Void = { _ in }) throws -> FirmwareTransaction {
        guard case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: f.vm) else { throw POSIXError(.EINVAL) }
        return try FirmwareTransaction(vmDirectory: f.vm,
            inputs: f.generation.content.originals.map { f.vm.appendingPathComponent($0.name) },
            options: ["variant": f.plan.variant, "generationID": f.generation.id, "desiredSHA256": try desired.sha256],
            plan: f.plan, versionInputs: FirmwareVersionInputs.read(in: f.vm), inject: inject, mounts: { _, _ in })
    }
}

extension FirmwareReceiptPublicationTests {
    func prepare(_ f: FirmwareComponentReceiptTests.Fixture, _ t: FirmwareTransaction) throws {
        let report = RequiredDeclarationEvidenceTests.complete(f.plan)
        let restore = try #require(f.generation.content.originals.first { $0.name.contains("Restore") }?.name)
        var outputs: [String: URL] = [:]
        for component in Set(report.allRecords.map { $0.component.lowercased() }) {
            let path = component == "avpbooter" ? f.file.lastPathComponent : restore + "/" + component + ".bin"
            let url = t.stage.appendingPathComponent(path)
            try Data([1]).write(to: url)
            outputs[component] = url
        }
        try t.saveReport(report)
        try t.prepareComponentReceipts(report: report, outputs: outputs)
    }

    @Test(arguments: [false, true]) func receiptFailureRollsBackPublication(_ prior: Bool) throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let receipt = f.vm.appendingPathComponent(".firmware-component-receipts.json")
        let old = Data("old receipt bytes".utf8)
        if prior { try old.write(to: receipt) }
        let original = try Data(contentsOf: f.file)
        let t = try begin(f) { if $0 == .afterPublish(".firmware-component-receipts.json") { throw POSIXError(.EIO) } }
        try prepare(f, t)
        #expect(throws: (any Error).self) { try t.commit() }
        #expect(t.journalSnapshot.phase != .committed)
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) != nil)
        #expect(try Data(contentsOf: f.file) == original)
        #expect(FileManager.default.fileExists(atPath: receipt.path) == prior)
        if prior { #expect(try Data(contentsOf: receipt) == old) }
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) == nil)
    }

    @Test func completeActualOutputReceiptsPublishInSameJournal() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let binding = f.vm.appendingPathComponent("launchpad.json")
        let oldBinding = Data("unrelated existing binding".utf8)
        try oldBinding.write(to: binding)
        let t = try begin(f)
        try prepare(f, t)
        let archive = try t.commit()
        #expect(try Data(contentsOf: f.file) == Data([1]))
        #expect(try Data(contentsOf: binding) == oldBinding)
        let receipt = try Data(contentsOf: f.vm.appendingPathComponent(".firmware-component-receipts.json"))
        #expect(try receipt == Data(contentsOf: archive.appendingPathComponent("component-receipts.json")))
        #expect(t.journalSnapshot.phase == .committed)
    }
}

extension FirmwareReceiptPublicationTests {
    @Test(arguments: ["receipt", "output", "desired", "disk", "write", "fsync", "metadata-backup", "detach", "before-commit"])
    func publicationFaultsCannotCommit(_ fault: String) throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let old = try Data(contentsOf: f.file)
        let receipt = f.vm.appendingPathComponent(".firmware-component-receipts.json")
        let t = try begin(f) { event in
            if fault == "write", event == .beforeMetadataWrite(".firmware-component-receipts.json") { throw POSIXError(.EACCES) }
            if fault == "fsync", event == .beforeMetadataSync(".firmware-component-receipts.json") { throw POSIXError(.EIO) }
            if fault == "metadata-backup", event == .afterBackup(".firmware-component-receipts.json") { throw POSIXError(.EINTR) }
            if event == .afterPublish(f.file.lastPathComponent) {
                if fault == "receipt" { try Data("corrupt".utf8).write(to: f.vm.appendingPathComponent(".firmware-transaction/component-receipts.json")) }
                if fault == "output" { try Data([2]).write(to: f.file) }
                if fault == "desired" {
                    let path = f.vm.appendingPathComponent(".firmware-desired-plan.json")
                    var data = try Data(contentsOf: path); data.append(10); try data.write(to: path)
                }
                if fault == "disk" { try Data("new disk".utf8).write(to: f.generationFixture.disk, options: .atomic) }
                if fault == "detach" { throw POSIXError(.EBUSY) }
            }
            if fault == "before-commit", event == .beforeCommitted { throw POSIXError(.EIO) }
        }
        #expect(throws: (any Error).self) { try prepare(f, t); try t.commit() }
        #expect(t.journalSnapshot.phase != .committed)
        if fault == "output" || fault == "disk" {
            // Unknown external bytes or replaced identity are retained explicitly.
            #expect(throws: (any Error).self) { try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) }
            #expect(FileManager.default.fileExists(atPath: t.root.path))
        } else {
            _ = try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in })
            #expect(try Data(contentsOf: f.file) == old)
            #expect(!FileManager.default.fileExists(atPath: receipt.path))
        }
    }

    @Test func metadataRollbackIsIdempotentAcrossRecoveryInterruption() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let receipt = f.vm.appendingPathComponent(".firmware-component-receipts.json")
        let old = Data("prior receipt".utf8); try old.write(to: receipt)
        let t = try begin(f) { if $0 == .beforeCommitted { throw POSIXError(.EINTR) } }
        try prepare(f, t)
        #expect(throws: (any Error).self) { try t.commit() }
        #expect(throws: (any Error).self) {
            try FirmwareTransaction.recover(vmDirectory: f.vm, inject: { if $0 == .afterRestore(".firmware-component-receipts.json") { throw POSIXError(.EINTR) } }, mounts: { _, _ in })
        }
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) != nil)
        #expect(try Data(contentsOf: receipt) == old)
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) == nil)
    }

    @Test func fullBinaryRecordIncludesUnchangedInstructionBytes() throws {
        let record = PatchRecord(patchID: "avpbooter.dgst_bypass", component: "avpbooter", fileOffset: 0,
            originalBytes: Data([0, 0, 0, 0]), patchedBytes: Data([1, 0, 0, 0]), description: "complete field")
        try FirmwareComponentReceipt.verifyEffect(record, payload: Data([1, 0, 0, 0]))
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.verifyEffect(record, payload: Data([1, 1, 0, 0])) }
    }

    @Test func publicationReadbackToolRunsUnderTheExistingTransactionLock() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        var transaction: FirmwareTransaction?
        var readbacks = 0
        let t = try begin(f) { event in
            guard event == .beforeCommitted, let transaction else { return }
            let output = try transaction.runTool("/usr/bin/printf", ["publication-readback"])
            #expect(output == Data("publication-readback".utf8))
            readbacks += 1
        }
        transaction = t
        try prepare(f, t)
        _ = try t.commit()
        #expect(readbacks == 1)
    }
}


extension FirmwareReceiptPublicationTests {
    @Test(arguments: ["success", "generated", "wrong-transaction", "stale-binding", "lost-qualification", "rollback", "wrong-layer", "lost-after-backup"])
    func installedOriginHookRequiresLiveTargetProof(_ fault: String) throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let bindingURL = f.vm.appendingPathComponent("launchpad.json")
        let original = try VPhoneMachineBinding(bundle: "2.6.1", guestEnvironment: "2.5.0", kernel: "2.4.0", bootChain: "2.3.0")
        let originalBytes = try JSONEncoder().encode(original); try originalBytes.write(to: bindingURL)
        let snapshot = try #require(try VPhoneMachineBinding.snapshot(f.vm))
        var lostQualification = false
        var publishedWithoutQualification = false
        let t = try begin(f) { event in
            if fault == "rollback", event == .afterPublish("launchpad.json") { throw POSIXError(.EINTR) }
            if fault == "lost-after-backup", event == .afterBackup("launchpad.json") { lostQualification = true }
            if event == .afterPublish("launchpad.json"), lostQualification { publishedWithoutQualification = true }
        }
        try prepare(f, t)
        let publication = try JSONDecoder().decode(FirmwareTransaction.ComponentPublication.self,
            from: Data(contentsOf: t.root.appendingPathComponent("component-receipts.json")))
        let base = try #require(publication.records.first { $0.component == "kernelcache" })
        let diskSHA = try FirmwareGeneration.fileSHA256(f.generationFixture.disk)
        let installed = FirmwareComponentReceipt.Record(schemaVersion: 1, component: "kernelcache",
            scope: fault == "generated" ? .generatedFirmware : .installedComponent, state: .committed,
            generationID: base.generationID, planSHA256: base.planSHA256, desiredSHA256: base.desiredSHA256,
            outputs: [.init(path: "Disk.img", sha256: diskSHA)], effects: base.effects.map { .init(declarationID: $0.declarationID, outputPath: "Disk.img", record: $0.record) })
        var checks = 0
        let origin = FirmwareTransaction.InstalledOrigin(transactionID: fault == "wrong-transaction" ? "other" : t.journalSnapshot.id,
            layer: fault == "wrong-layer" ? .guestEnvironment : .kernel, expected: snapshot,
            binding: try original.replacingOrigin(fault == "wrong-layer" ? .guestEnvironment : .kernel, with: "2.6.2"),
            receipt: installed, proof: Data("actual synthetic installed proof".utf8), recheck: { point in
                checks += 1
                if lostQualification { throw POSIXError(.EACCES) }
                #expect(try FirmwareGeneration.fileSHA256(f.generationFixture.disk) == diskSHA)
                if fault == "lost-qualification", point == .published { throw POSIXError(.EACCES) }
                if fault == "stale-binding", point == .published {
                    try JSONEncoder().encode(original.replacingHost(with: "2.6.3")).write(to: bindingURL)
                }
            })
        if fault == "success" {
            _ = try t.commit(origin: origin)
            let next = try #require(try VPhoneMachineBinding.snapshot(f.vm)).binding
            #expect(next.kernel == "2.6.2")
            #expect(next.bundle == "2.6.1" && next.bootChain == "2.3.0" && next.guestEnvironment == "2.5.0")
            #expect(checks >= 3)
        } else {
            #expect(throws: (any Error).self) { try t.commit(origin: origin) }
            #expect(t.journalSnapshot.phase != .committed)
            #expect(!publishedWithoutQualification)
            if fault != "stale-binding" {
                _ = try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in })
                #expect(try Data(contentsOf: bindingURL) == originalBytes)
            } else {
                #expect(throws: (any Error).self) { try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) }
            }
        }
    }
}

extension FirmwareReceiptPublicationTests {
    @Test func oldCommittedGenerationJournalRemainsRecoveryOnlyReadable() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let t = try begin(f)
        let url = t.root.appendingPathComponent("journal.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["phase"] = "committed"
        var entries = try #require(object["entries"] as? [[String: Any]])
        for index in entries.indices { entries[index]["output"] = entries[index]["original"] }
        object["entries"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) != nil)
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) == nil)
    }
}


extension FirmwareReceiptPublicationTests {
    @Test func committedJournalFsyncFailureRetainsRecovery() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let t = try begin(f) { if $0 == .beforeJournalSync(.committed) { throw POSIXError(.EIO) } }
        try prepare(f, t)
        #expect(throws: (any Error).self) { try t.commit() }
        #expect(t.journalSnapshot.phase != .committed)
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) != nil)
        #expect(try Data(contentsOf: f.file) == Data("original boot rom".utf8))
    }

    @Test func receiptMustCoverTheExactSavedReportRecords() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let t = try begin(f); try prepare(f, t)
        let report = RequiredDeclarationEvidenceTests.complete(f.plan)
        let components = report.components.map { component -> ComponentReport in
            guard component.component == "avpbooter" else { return component }
            let r = component.records[0]
            let changed = PatchRecord(patchID: r.patchID, component: r.component, fileOffset: r.fileOffset,
                originalBytes: Data([9]), patchedBytes: r.patchedBytes, description: "another operation")
            return ComponentReport(component: component.component, coverage: component.coverage,
                results: component.results, records: [changed])
        }
        try t.saveReport(PatchRunReport(variant: report.variant, gates: report.gates, components: components, ablation: []))
        #expect(throws: (any Error).self) { try t.commit() }
        #expect(t.journalSnapshot.phase != .committed)
    }
}

extension FirmwareReceiptPublicationTests {
    @Test func receiptMetadataRefusalKeepsRecoverableJournal() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let target = f.vm.appendingPathComponent("external-receipt")
        try Data("preserved external receipt".utf8).write(to: target)
        let receipt = f.vm.appendingPathComponent(".firmware-component-receipts.json")
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: target)
        let t = try begin(f)
        do { try prepare(f, t); Issue.record("linked receipt unexpectedly accepted") }
        catch { t.recordFailure(error) }
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) != nil)
        #expect(try Data(contentsOf: target) == Data("preserved external receipt".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: receipt.path) == target.path)
    }
}

extension FirmwareReceiptPublicationTests {
    @Test func corruptPublishedReceiptRetainsExplicitRecoveryUncertainty() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let receipt = f.vm.appendingPathComponent(".firmware-component-receipts.json")
        let t = try begin(f) { event in
            if event == .afterPublish(".firmware-component-receipts.json") { try Data("external corruption".utf8).write(to: receipt) }
        }
        try prepare(f, t)
        #expect(throws: (any Error).self) { try t.commit() }
        #expect(t.journalSnapshot.phase != .committed)
        #expect(throws: (any Error).self) { try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) }
        #expect(try Data(contentsOf: receipt) == Data("external corruption".utf8))
        #expect(FileManager.default.fileExists(atPath: t.root.path))
    }
}


extension FirmwareReceiptPublicationTests {
    @Test(arguments: ["preserved-file", "new-member", "unchanged-root"])
    func finalWindowMutationOfJournalRootCannotCommit(_ fault: String) throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let restore = try #require(f.generation.content.originals.first { $0.name.contains("Restore") }?.name)
        let target = f.vm.appendingPathComponent(restore + (fault == "preserved-file" ? "/Firmware/test.im4p" : "/external/member"))
        let altered = Data("unknown final-window bytes".utf8)
        let mutate: (FirmwareTransaction.Event) throws -> Void = { event in
            if event == .beforeCommitted {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try altered.write(to: target)
            }
        }
        let t: FirmwareTransaction
        if fault == "unchanged-root" {
            // A historical/manual transaction can have an unchanged entire root.
            // Its output digest still constrains the final commit window.
            t = try FirmwareTransaction(vmDirectory: f.vm, inputs: [f.vm.appendingPathComponent(restore)],
                options: [:], inject: mutate, mounts: { _, _ in })
        } else {
            t = try begin(f, inject: mutate)
            try prepare(f, t)
        }
        #expect(throws: (any Error).self) { try t.commit() }
        #expect(t.journalSnapshot.phase == .publishing)
        #expect(throws: (any Error).self) { try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) }
        #expect(try Data(contentsOf: target) == altered)
        #expect(FileManager.default.fileExists(atPath: t.root.appendingPathComponent("journal.json").path))
        let journal = try FirmwareTransaction.readJournal(at: t.root.appendingPathComponent("journal.json"))
        #expect(journal.phase == .publishing)
        if fault == "unchanged-root" {
            #expect(journal.entries[0].output == journal.entries[0].original)
        }
    }
}


extension FirmwareReceiptPublicationTests {
    @Test(arguments: [false, true])
    func startedWorkerIOFailureWaitsAndDrainsBeforeUnlock(_ fileOutput: Bool) throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let markers = f.generationFixture.root.appendingPathComponent("worker-io")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: false)
        let started = markers.appendingPathComponent("started")
        let done = markers.appendingPathComponent("done")
        let probe = markers.appendingPathComponent("recovery")
        let output = markers.appendingPathComponent("output")
        if fileOutput { try Data().write(to: output) }
        let vm = f.vm
        let observer = DispatchGroup()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let python = repo.appendingPathComponent(".venv/bin/python3").path
        let program = #"""
        import os,sys,signal,time
        from pathlib import Path
        signal.alarm(15)
        root=Path(sys.argv[1]);(root/'started').write_text('running')
        while not (root/'recovery').exists(): time.sleep(0.01)
        total=0
        try:
            for fd in (1,2):
                chunk=b'x'*65536
                for i in range(32):
                    view=memoryview(chunk)
                    while view:
                        n=os.write(fd,view);total+=n;view=view[n:]
        except OSError: pass
        (root/'done').write_text(str(total))
        """#
        var transaction: FirmwareTransaction?
        let t = try begin(f) { event in
            if event == .beforeCommitted, let transaction {
                _ = try transaction.runTool(python, ["-c", program, markers.path], output: fileOutput ? output : nil)
            }
            if event == .afterToolStart {
                let deadline = Date().addingTimeInterval(10)
                while !FileManager.default.fileExists(atPath: started.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                guard FileManager.default.fileExists(atPath: started.path) else { throw POSIXError(.ETIMEDOUT) }
                observer.enter()
                DispatchQueue.global().async {
                    defer { observer.leave() }
                    // Give the erroneous early-return path time to unlock. The
                    // child waits for this actual recovery attempt before output.
                    Thread.sleep(forTimeInterval: 0.3)
                    let result: String
                    do { _ = try FirmwareTransaction.recover(vmDirectory: vm, mounts: { _, _ in }); result = "allowed" }
                    catch { result = error.localizedDescription }
                    try? Data(result.utf8).write(to: probe)
                }
                throw POSIXError(.EIO)
            }
        }
        transaction = t
        try prepare(f, t)
        do { _ = try t.commit(); Issue.record("I/O fault unexpectedly committed") }
        catch { #expect((error as? POSIXError)?.code == .EIO) }
        let finishedAtReturn = FileManager.default.fileExists(atPath: done.path)
        // Bound RED cleanup as well: the fixture must not vanish under a child.
        #expect(observer.wait(timeout: .now() + 10) == .success)
        let deadline = Date().addingTimeInterval(16)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(finishedAtReturn)
        #expect(try String(contentsOf: probe, encoding: .utf8).contains("Firmware tool is still running"))
        #expect(try String(contentsOf: done, encoding: .utf8) == "4194304")
        if fileOutput { #expect(try Data(contentsOf: output).count == 4 * 1024 * 1024) }
        #expect(t.journalSnapshot.phase == .publishing)
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) != nil)
    }
}

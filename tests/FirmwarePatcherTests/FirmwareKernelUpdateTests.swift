import Foundation
import Testing
import VPhoneCore
@testable import FirmwarePatcher

@Suite struct FirmwareKernelUpdateTests {
    @Test func unknownKernelCapacityIsRefused() throws {
        #expect(throws: (any Error).self) { try FirmwareKernelRegion.inspect(Data(repeating: 0, count: 256)) }
    }

    struct DiskFixture {
        let fixture: FirmwareGenerationTests.Fixture
        let root: URL
        let before = Data(repeating: 7, count: 8192)
        let after = Data(repeating: 8, count: 8192)
        var target: URL { fixture.disk }
        let initial: FirmwareKernelDisk
        init() throws {
            fixture = try FirmwareGenerationTests.Fixture()
            root = fixture.vm.appendingPathComponent("disk-test")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try before.write(to: fixture.disk)
            let candidate = root.appendingPathComponent("candidate.img")
            try after.write(to: candidate)
            initial = try FirmwareKernelDisk.capture(directory: fixture.vm, root: root, candidate: candidate)
        }
    }

    @Test func knownDiskInterruptionRestoresOriginalBytes() throws {
        let f = try DiskFixture()
        var disk = f.initial, saved = disk
        #expect(throws: (any Error).self) {
            try disk.publish(directory: f.fixture.vm, root: f.root, save: { saved = $0 }, afterWrite: { _ in throw POSIXError(.EINTR) })
        }
        #expect(saved.pending)
        try saved.reverse(directory: f.fixture.vm, root: f.root, save: { _ in }, afterWrite: { _ in })
        #expect(try Data(contentsOf: f.target) == f.before)
    }

    @Test func unknownExternalDiskEditIsNotOverwrittenByRecovery() throws {
        let f = try DiskFixture()
        var disk = f.initial, saved = disk
        try? disk.publish(directory: f.fixture.vm, root: f.root, save: { saved = $0 }, afterWrite: { _ in throw POSIXError(.EINTR) })
        let external = Data(repeating: 9, count: 8192)
        try external.write(to: f.target)
        #expect(throws: (any Error).self) {
            try saved.reverse(directory: f.fixture.vm, root: f.root, save: { _ in }, afterWrite: { _ in })
        }
        #expect(try Data(contentsOf: f.target) == external)
    }

    @Test(arguments: [false, true]) func reverseInterruptionCanResume(_ partialForward: Bool) throws {
        let f = try DiskFixture()
        var disk = f.initial, saved = disk
        if partialForward {
            try? disk.publish(directory: f.fixture.vm, root: f.root, save: { saved = $0 }, afterWrite: { _ in throw POSIXError(.EINTR) })
        } else {
            try disk.publish(directory: f.fixture.vm, root: f.root, save: { saved = $0 }, afterWrite: { _ in })
        }
        disk = saved
        #expect(throws: (any Error).self) {
            try disk.reverse(directory: f.fixture.vm, root: f.root, save: { saved = $0 }, afterWrite: { _ in throw POSIXError(.EINTR) })
        }
        disk = saved
        try disk.reverse(directory: f.fixture.vm, root: f.root, save: { saved = $0 }, afterWrite: { _ in })
        #expect(try Data(contentsOf: f.target) == f.before)
        try disk.reverse(directory: f.fixture.vm, root: f.root, save: { _ in }, afterWrite: { _ in })
    }

    @Test(arguments: [false, true], ["replace", "edit", "truncate"])
    func prewriteChangesArePreserved(_ reverse: Bool, _ fault: String) throws {
        let f = try DiskFixture()
        var disk = f.initial
        if reverse { try disk.publish(directory: f.fixture.vm, root: f.root, save: { _ in }, afterWrite: { _ in }) }
        var external: Data?
        let save: (FirmwareKernelDisk) throws -> Void = { state in
            guard state.pending, external == nil else { return }
            var changed = try Data(contentsOf: f.target)
            if fault == "truncate" { changed.removeLast() }
            else { changed[reverse ? 4096 : 0] = 9 }
            try changed.write(to: f.target, options: fault == "replace" ? .atomic : [])
            external = changed
        }
        #expect(throws: (any Error).self) {
            if reverse { try disk.reverse(directory: f.fixture.vm, root: f.root, save: save, afterWrite: { _ in }) }
            else { try disk.publish(directory: f.fixture.vm, root: f.root, save: save, afterWrite: { _ in }) }
        }
        #expect(try Data(contentsOf: f.target) == external)
    }

    @Test func pendingJournalFailurePreventsWrite() throws {
        let f = try DiskFixture()
        var disk = f.initial
        #expect(throws: (any Error).self) {
            try disk.publish(directory: f.fixture.vm, root: f.root,
                             save: { _ in throw POSIXError(.ENOSPC) }, afterWrite: { _ in })
        }
        #expect(try Data(contentsOf: f.target) == f.before)
    }

    @Test func kernelGatePreservesRequiredEvidenceAndRejectsOtherComponents() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let complete = RequiredDeclarationEvidenceTests.complete(f.plan)
        let kernel = PatchRunReport(variant: f.plan.variant, gates: f.plan.gates,
            components: complete.components.filter { $0.component.lowercased() == "kernelcache" }, ablation: [])
        try PatchDeclarationGate.enforceKernel(report: kernel, plan: f.plan)
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: kernel, plan: f.plan) }
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforceKernel(report: complete, plan: f.plan) }
        for entry in f.plan.selected where entry.required && entry.swiftSteps.contains(where: { $0.hasPrefix("kernelcache.") }) {
            let incomplete = RequiredDeclarationEvidenceTests.complete(f.plan, omitting: entry.id)
            let missing = PatchRunReport(variant: f.plan.variant, gates: f.plan.gates,
                components: incomplete.components.filter { $0.component.lowercased() == "kernelcache" }, ablation: [])
            #expect(throws: (any Error).self) { try PatchDeclarationGate.enforceKernel(report: missing, plan: f.plan) }
        }
        let empty = PatchRunReport(variant: f.plan.variant, gates: f.plan.gates, components: [], ablation: [])
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforceKernel(report: empty, plan: f.plan) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_KERNEL_REGION_FIXTURE"] != nil))
    func actualCandidateRegionUsesSourceFlow() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_KERNEL_REGION_FIXTURE"])
        let region = try FirmwareKernelRegion.inspect(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(region.base == 0x180000000)
        #expect(region.size == 0x180000000)
    }
}

extension FirmwareKernelUpdateTests {
    @Test(arguments: ["success", "disk-write", "receipt", "binding", "commit", "archive"])
    func diskAndOriginShareOneRecoveryJournal(_ fault: String) throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let disk = f.generationFixture.disk
        let before = Data(repeating: 7, count: 8192), after = Data(repeating: 8, count: 8192)
        try before.write(to: disk)
        let bindingURL = f.vm.appendingPathComponent("launchpad.json")
        let binding = try VPhoneMachineBinding(bundle: "2.6.1", guestEnvironment: "2.5.0", kernel: "2.4.0", bootChain: "2.3.0")
        let originalBinding = try JSONEncoder().encode(binding)
        try originalBinding.write(to: bindingURL)
        let snapshot = try #require(try VPhoneMachineBinding.snapshot(f.vm))
        guard case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: f.vm) else { throw POSIXError(.EINVAL) }
        // Live restore artifacts may differ from generation originals. A kernel
        // update neither reads them as source nor publishes replacements for them.
        let unrelated = Data("already patched restore artifact".utf8)
        try unrelated.write(to: f.file)
        let t = try FirmwareTransaction(vmDirectory: f.vm,
            inputs: FirmwareGeneration.originalURLs(in: f.vm, id: f.generation.id),
            options: ["variant": f.plan.variant, "generationID": f.generation.id, "desiredSHA256": desired.sha256],
            plan: f.plan, versionInputs: FirmwareVersionInputs.read(in: f.vm), kernelOnly: true,
            inject: { event in
                if fault == "disk-write", event == .afterPublish("Disk.img") { throw POSIXError(.EINTR) }
                if fault == "receipt", event == .afterPublish(".firmware-component-receipts.json") { throw POSIXError(.EINTR) }
                if fault == "binding", event == .afterPublish("launchpad.json") { throw POSIXError(.EINTR) }
                if fault == "commit", event == .beforeCommitted { throw POSIXError(.EINTR) }
                if fault == "archive", event == .beforeArchive { throw POSIXError(.EINTR) }
            }, mounts: { _, _ in })
        let candidate = t.work.appendingPathComponent("candidate.img")
        try after.write(to: candidate)
        try t.prepareKernelDisk(candidate: candidate)
        let full = RequiredDeclarationEvidenceTests.complete(f.plan)
        let report = PatchRunReport(variant: f.plan.variant, gates: f.plan.gates,
            components: full.components.filter { $0.component.lowercased() == "kernelcache" }, ablation: [])
        try t.saveReport(report)
        try t.prepareKernelReceipts(report: report)
        let effects = try report.allRecords.map { record -> FirmwareComponentReceipt.Effect in
            let owner = try #require(f.plan.selected.first { ($0.recordRules ?? []).contains { $0.matches(record) } })
            return .init(declarationID: owner.id, outputPath: "Disk.img", record: record)
        }
        let installed = FirmwareComponentReceipt.Record(schemaVersion: 1, component: "kernelcache", scope: .installedComponent,
            state: .committed, generationID: f.generation.id, planSHA256: try FirmwareGeneration.planDigest(f.plan),
            desiredSHA256: try desired.sha256, outputs: [.init(path: "Disk.img", sha256: VPhoneCreateDigest.sha256(after))], effects: effects)
        let origin = FirmwareTransaction.InstalledOrigin(transactionID: t.journalSnapshot.id, layer: .kernel,
            expected: snapshot, binding: try binding.replacingOrigin(.kernel, with: "2.6.2"), receipt: installed,
            proof: Data("synthetic live qualification".utf8), recheck: { point in
                let actual = try Data(contentsOf: disk)
                #expect(actual == (point == .candidate ? before : after))
            })
        if fault == "success" { _ = try t.commit(origin: origin) }
        else {
            #expect(throws: (any Error).self) { try t.commit(origin: origin) }
            _ = try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in })
        }
        let committed = fault == "success" || fault == "archive"
        #expect(try Data(contentsOf: disk) == (committed ? after : before))
        #expect(try Data(contentsOf: f.file) == unrelated)
        let current = try #require(try VPhoneMachineBinding.snapshot(f.vm)).binding
        #expect(current == (committed ? try binding.replacingOrigin(.kernel, with: "2.6.2") : binding))
        if committed {
            let receipts = try #require(try FirmwareComponentReceipt.readCommitted(in: f.vm))
            #expect(receipts == [installed])
        } else {
            #expect(try Data(contentsOf: bindingURL) == originalBinding)
            #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(".firmware-component-receipts.json").path))
        }
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) == nil)
    }
}

extension FirmwareKernelUpdateTests {
    @Test(arguments: ["ready", "publishing", "committed"])
    func kernelPublicationSchemaRequiresDiskRelationship(_ phase: String) throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let t = try FirmwareReceiptPublicationTests().begin(f)
        let path = t.root.appendingPathComponent("journal.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        object["version"] = 3; object["kernelOnly"] = true; object["phase"] = phase
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        #expect(throws: (any Error).self) { try FirmwareTransaction.readJournal(at: path) }
    }
}

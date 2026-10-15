import Foundation
import Img4tool
import Testing
import VPhoneCore
@testable import FirmwarePatcher

@Suite struct FirmwareKernelRollbackTests {
    struct Fixture {
        let firmware: FirmwareComponentReceiptTests.Fixture
        let executable: URL
        var vm: URL { firmware.vm }
        var disk: URL { vm.appendingPathComponent("Disk.img") }
        init() throws {
            firmware = try .init(kernelInput: KernelcacheMetadataTests.source(Data(repeating: 0, count: 256)))
            executable = firmware.generationFixture.root.appendingPathComponent("vphone-cli")
            try Data("same verified producer".utf8).write(to: executable)
            try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.2", guestEnvironment: "2.5.0", kernel: "2.4.0", bootChain: "2.3.0")).write(to: vm.appendingPathComponent("launchpad.json"))
            var disk = Data(repeating: 0, count: 12288)
            let image = KernelcacheSwapTests.target(KernelcacheMetadataTests.source(Data(repeating: 0, count: 256)))
            Self.setImage(image, in: &disk)
            try disk.write(to: self.disk)
        }
        func session<T>(_ body: (FirmwareInstalledOrigin.Session) throws -> T) throws -> T {
            try FirmwareInstalledOrigin.withVerifiedSource(version: "2.6.2", executable: executable, effectiveExecutable: executable, recheck: {}, body: body)
        }
        func desired() throws -> FirmwareDesiredPlanStore.Record {
            guard case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: vm) else { throw POSIXError(.EINVAL) }
            return desired
        }
        func plan(force: Bool) throws -> VariantPlanResolver.VariantPlan {
            try FirmwarePipeline(vmDirectory: vm, variant: .regular, verbose: false, forceExcGuard: force).resolvedPlan()
        }
        func select(force: Bool) throws {
            let prepared = try FirmwareDesiredPlanStore.prepare(in: vm, plan: plan(force: force), generation: firmware.generation)
            _ = try FirmwareDesiredPlanStore.publish(prepared, expectedSHA256: prepared.expectedSHA256)
        }
        func update() throws -> String {
            let desired = try desired()
            let prepared = try FirmwareKernelUpdate.prepare(in: vm, plan: desired.plan, generation: firmware.generation)
            _ = try session { try FirmwareKernelUpdate.publish(prepared, session: $0, expected: prepared.binding, operations: operations()) }
            return try currentTransaction()
        }
        func currentTransaction() throws -> String {
            let data = try Data(contentsOf: vm.appendingPathComponent(".firmware-component-receipts.json"))
            return try JSONDecoder().decode(FirmwareTransaction.ComponentPublication.self, from: data).transactionID
        }
        func rollback(_ prepared: FirmwareKernelRollback.Prepared, operations: FirmwareKernelUpdate.Operations? = nil) throws {
            _ = try session { try FirmwareKernelUpdate.publish(prepared.update, session: $0, expected: prepared.update.binding, operations: operations ?? self.operations()) }
        }
        func operations() -> FirmwareKernelUpdate.Operations {
            var operations = FirmwareKernelUpdate.Operations()
            operations.mounts = { _, _ in }
            operations.region = { _ in .init(base: 0x180000000, size: 6 << 30) }
            operations.producer = { _, input, plan in
                let byte: UInt8 = plan.gates.forceExcGuard ? 2 : 1
                var actual = Data(input); actual[0] = byte
                var first = true
                let reports = RequiredDeclarationEvidenceTests.complete(plan).components.filter { $0.component.lowercased() == "kernelcache" }.map { report in
                    let records = report.records.map { record in
                        let original = first ? Data([0]) : Data([byte]); first = false
                        return PatchRecord(patchID: record.patchID, component: record.component, fileOffset: 0,
                            originalBytes: original, patchedBytes: Data([byte]), description: "synthetic actual producer")
                    }
                    return ComponentReport(component: report.component, coverage: report.coverage, results: report.results, records: records)
                }
                return (actual, reports)
            }
            operations.volumes = { transaction, writable in Self.volumes(transaction, writable: writable) }
            return operations
        }
        static func image(in disk: Data) -> Data {
            let count = Int(disk.loadLE(UInt32.self, at: 0))
            return disk.subdata(in: 4..<4 + count)
        }
        static func setImage(_ image: Data, in disk: inout Data) {
            var count = UInt32(image.count).littleEndian
            withUnsafeBytes(of: &count) { disk.replaceSubrange(0..<4, with: $0) }
            disk.replaceSubrange(4..<4096, with: image + Data(repeating: 0, count: 4092 - image.count))
        }
        static func volumes(_ transaction: FirmwareTransaction, writable: Bool) -> FirmwareInstalledReadback.Operations {
            .init(attach: { image, work in
                let mount = work.appendingPathComponent("mock-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
                var volumes: [String: FirmwareInstalledReadback.Volume] = [:]
                for (name, suffix) in ["system": "s1", "hardware": "s3", "preboot": "s5"] {
                    let root = mount.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                    volumes[name] = .init(device: "disk998" + suffix, root: root)
                }
                try Self.image(in: Data(contentsOf: image)).write(to: volumes["preboot"]!.root.appendingPathComponent("kernelcache"))
                let dsc = volumes["system"]!.root.appendingPathComponent("System/Cryptexes/OS/System/Library/Caches/com.apple.dyld")
                try FileManager.default.createDirectory(at: dsc, withIntermediateDirectories: true)
                var header = Data(repeating: 0, count: 4096)
                header.replaceSubrange(0..<7, with: Data("dyld_v1".utf8))
                func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
                    var le = value.littleEndian
                    withUnsafeBytes(of: &le) { header.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
                }
                put(UInt32(0x200), 0x10); put(UInt32(1), 0x14)
                put(UInt64(0x180000000), 0xE0); put(UInt64(4096), 0xE8)
                put(UInt64(0x180000000), 0x200); put(UInt64(4096), 0x208)
                try header.write(to: dsc.appendingPathComponent("dyld_shared_cache_arm64e"))
                return .init(image: image, device: "/dev/disk999", volumes: volumes)
            }, inspect: { attachment in
                func plist(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
                let volumes = attachment.volumes
                return try .init(images: plist(["images": [["image-path": attachment.image.path, "system-entities": [["dev-entry": "/dev/disk999"]]]]]),
                    containers: plist(["Containers": [["ContainerReference": "disk998", "PhysicalStores": [["DeviceIdentifier": "disk999s1"]],
                        "Volumes": volumes.values.map { ["DeviceIdentifier": $0.device, "MountPoint": $0.root.path] }]]]),
                    volumes: volumes.mapValues { try plist(["DeviceIdentifier": $0.device, "MountPoint": $0.root.path, "ReadOnlyVolume": !(writable && $0.device.hasSuffix("s5"))]) })
            }, detach: { attachment in
                if writable {
                    var disk = try Data(contentsOf: attachment.image)
                    Self.setImage(try Data(contentsOf: attachment.volumes["preboot"]!.root.appendingPathComponent("kernelcache")), in: &disk)
                    try disk.write(to: attachment.image)
                }
                try FileManager.default.removeItem(at: attachment.volumes["preboot"]!.root.deletingLastPathComponent())
            })
        }
    }

    @Test func differentPlanRollbackPreservesPostBootDataAndLiveDesired() throws {
        let f = try Fixture()
        let a = try f.update()
        let old = try FirmwareKernelHistory.read(in: f.vm, transactionID: a)
        try f.select(force: true)
        _ = try f.update()
        let before = try Data(contentsOf: f.disk)
        #expect(try IM4P(IMG4(Fixture.image(in: before)).im4p().data).payload().first == 2)
        var postBoot = before; postBoot[8192] = 0xA7
        try postBoot.write(to: f.disk)
        let desired = try Data(contentsOf: f.vm.appendingPathComponent(FirmwareDesiredPlanStore.filename))
        let binding = try #require(try VPhoneMachineBinding.snapshot(f.vm)).binding
        let identity = try VPhoneFirmwareIdentity.read(in: f.vm)
        let prepared = try FirmwareKernelRollback.prepare(in: f.vm, transactionID: a)
        #expect(prepared.targetPlanSHA256 != (try f.desired()).planSHA256)
        try f.rollback(prepared)
        let actual = try Data(contentsOf: f.disk)
        #expect(actual[8192] == 0xA7)
        #expect(actual.dropFirst(4096) == postBoot.dropFirst(4096))
        #expect(try VPhoneFirmwareIdentity.read(in: f.vm) == identity)
        let im4p = try IMG4(Fixture.image(in: actual)).im4p()
        #expect(try im4p.payload().first == 1)
        #expect(VPhoneCreateDigest.sha256(im4p.data) == old.im4pSHA256)
        #expect(try Data(contentsOf: f.vm.appendingPathComponent(FirmwareDesiredPlanStore.filename)) == desired)
        #expect(try VPhoneMachineBinding.snapshot(f.vm)?.binding == binding)
        let id = try f.currentTransaction()
        #expect(id != a)
        let journal = try FirmwareTransaction.readJournal(at: f.vm.appendingPathComponent(".firmware-history/" + id + "/journal.json"))
        #expect(journal.version == 4 && journal.rollbackSelection?.targetTransactionID == a)
        #expect(try FirmwareKernelHistory.read(in: f.vm, transactionID: id).im4pSHA256 == old.im4pSHA256)
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) == nil)
    }

    @Test(arguments: ["desired", "binding", "disk", "artifact", "source-code", "expired", "fresh-output", "required-record"])
    func changedQualificationCannotPublish(_ fault: String) throws {
        let f = try Fixture(), target = try f.update()
        try f.select(force: true); _ = try f.update()
        let prepared = try FirmwareKernelRollback.prepare(in: f.vm, transactionID: target)
        let original = try Data(contentsOf: f.disk)
        var operations = f.operations()
        if fault == "desired" { try f.select(force: false) }
        if fault == "binding" { try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.3")).write(to: f.vm.appendingPathComponent("launchpad.json")) }
        if fault == "disk" { var data = original; data[8192] = 7; try data.write(to: f.disk) }
        if fault == "artifact" { try Data([0]).write(to: f.vm.appendingPathComponent(".firmware-history/" + target + "/" + FirmwareKernelHistory.artifactName)) }
        if fault == "source-code" { try Data("changed producer".utf8).write(to: f.executable) }
        if fault == "fresh-output" {
            let producer = operations.producer
            operations.producer = { pipeline, input, plan in
                let (data, reports) = try producer(pipeline, input, plan)
                var changed = data; changed[10] = 3
                return (changed, reports)
            }
        }
        if fault == "required-record" {
            let producer = operations.producer
            operations.producer = { pipeline, input, plan in
                let (data, reports) = try producer(pipeline, input, plan)
                return (data, Array(reports.dropFirst()))
            }
        }
        if fault == "expired" {
            var escaped: FirmwareInstalledOrigin.Session?
            try f.session { escaped = $0 }
            #expect(throws: (any Error).self) {
                try FirmwareKernelUpdate.publish(prepared.update, session: escaped!, expected: prepared.update.binding, operations: operations)
            }
        } else {
            #expect(throws: (any Error).self) { try f.rollback(prepared, operations: operations) }
        }
        #expect(try Data(contentsOf: f.disk) == (fault == "disk" ? { var data = original; data[8192] = 7; return data }() : original))
        if FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(".firmware-transaction").path) {
            _ = try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in })
        }
    }

    @Test(arguments: ["disk-write", "receipt", "binding", "commit", "archive", "desired-cas"])
    func interruptedRollbackRestoresItsStartingDiskAndMetadata(_ fault: String) throws {
        let f = try Fixture(), target = try f.update()
        try f.select(force: true); _ = try f.update()
        var postBoot = try Data(contentsOf: f.disk); postBoot[8192] = 77; try postBoot.write(to: f.disk)
        let receipt = try Data(contentsOf: f.vm.appendingPathComponent(".firmware-component-receipts.json"))
        let binding = try Data(contentsOf: f.vm.appendingPathComponent("launchpad.json"))
        let desired = try Data(contentsOf: f.vm.appendingPathComponent(FirmwareDesiredPlanStore.filename))
        let prepared = try FirmwareKernelRollback.prepare(in: f.vm, transactionID: target)
        var operations = f.operations(), fired = false
        operations.inject = { event in
            let hit = fault == "disk-write" && event == .afterPublish("Disk.img") ||
                fault == "receipt" && event == .afterPublish(".firmware-component-receipts.json") ||
                fault == "binding" && event == .afterPublish("launchpad.json") ||
                fault == "commit" && event == .beforeCommitted || fault == "archive" && event == .beforeArchive ||
                fault == "desired-cas" && event == .afterPublish("Disk.img")
            if hit && !fired {
                fired = true
                if fault == "desired-cas" { try Data("external desired CAS change".utf8).write(to: f.vm.appendingPathComponent(FirmwareDesiredPlanStore.filename)); return }
                throw POSIXError(.EINTR)
            }
        }
        #expect(throws: (any Error).self) { try f.rollback(prepared, operations: operations) }
        #expect(fired)
        _ = try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in })
        let actual = try Data(contentsOf: f.disk)
        #expect(actual[8192] == 77)
        if fault != "archive" {
            #expect(actual == postBoot)
            #expect(try Data(contentsOf: f.vm.appendingPathComponent(".firmware-component-receipts.json")) == receipt)
            #expect(try Data(contentsOf: f.vm.appendingPathComponent("launchpad.json")) == binding)
        }
        #expect(try Data(contentsOf: f.vm.appendingPathComponent(FirmwareDesiredPlanStore.filename)) == (fault == "desired-cas" ? Data("external desired CAS change".utf8) : desired))
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) == nil)
    }
}

extension FirmwareKernelRollbackTests {
    /// Pure-file fixture: this executes the actual kernel producer and its full
    /// declaration gate. It never attaches an image or starts a VM.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_TEST_ROLLBACK_PRISTINE"] != nil))
    func actualPublicForceExcGuardPlansProduceDifferentPayloads() throws {
        let env = ProcessInfo.processInfo.environment
        let source = try Data(contentsOf: URL(fileURLWithPath: #require(env["VPHONE_TEST_ROLLBACK_PRISTINE"])))
        #expect(VPhoneCreateDigest.sha256(source) == (try #require(env["VPHONE_TEST_ROLLBACK_INPUT_SHA256"])))
        let pristine = Data(try IM4P(source).payload())
        var hashes: [String] = [], evidence: [[String: Any]] = []
        let variant = try #require(FirmwarePipeline.Variant(rawValue: env["VPHONE_TEST_ROLLBACK_VARIANT"] ?? "exp"))
        for force in [false, true] {
            let gates = PatchGateSnapshot(variant: variant.rawValue, iosBaseIs18: false, iosBaseIs27: false,
                cloudOSIsFridaCapable: false, forceExcGuard: force, enableFrida: false,
                excGuardActive: variant == .dev || force, applyIOS27: false, applyFrida: false, guestEnvironmentV2: false)
            let plan = try VariantPlanResolver.resolve(variant: variant, gates: gates)
            let pipeline = FirmwarePipeline(vmDirectory: URL(fileURLWithPath: "/nonexistent/pure-rollback-producer"),
                variant: variant, verbose: false, forceExcGuard: force)
            let (actual, components) = try pipeline.reproduceInstalledComponentReport("kernelcache", input: pristine, plan: plan)
            let report = PatchRunReport(variant: plan.variant, gates: gates, components: components, ablation: [])
            try PatchDeclarationGate.enforceKernel(report: report, plan: plan)
            var reconstructed = pristine
            for record in report.allRecords {
                #expect(reconstructed.subdata(in: record.fileOffset..<record.fileOffset + record.originalBytes.count) == record.originalBytes)
                reconstructed.replaceSubrange(record.fileOffset..<record.fileOffset + record.originalBytes.count, with: record.patchedBytes)
                try FirmwareComponentReceipt.verifyEffect(record, payload: actual)
            }
            #expect(reconstructed == actual)
            let region = try FirmwareKernelRegion.inspect(actual)
            var dsc = "unverified; no system fixture supplied"
            if let path = env["VPHONE_TEST_ROLLBACK_DSC_SYSTEM"] {
                try FirmwareKernelDSC.validate(system: URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath(), region: region)
                dsc = "passed"
            }
            let digest = VPhoneCreateDigest.sha256(actual); hashes.append(digest)
            let im4p = try VPhoneKernelcacheSwap.repackKernelPayload(actual, sourceIM4P: source)
            evidence.append(["forceExcGuard": force, "planSHA256": try FirmwareGeneration.planDigest(plan),
                "payloadSHA256": digest, "im4pSHA256": VPhoneCreateDigest.sha256(im4p),
                "recordCount": report.allRecords.count, "sharedRegionBase": region.base,
                "sharedRegionSize": region.size, "dsc": dsc])
        }
        #expect(hashes[0] != hashes[1])
        if let path = env["VPHONE_TEST_ROLLBACK_PAIR_OUT"] {
            try JSONSerialization.data(withJSONObject: ["inputSHA256": VPhoneCreateDigest.sha256(source),
                "variant": variant.rawValue, "payloadsDiffer": hashes[0] != hashes[1], "plans": evidence], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }
    }
}

extension FirmwareKernelRollbackTests {
    static func rewriteHistory(_ f: Fixture, id: String, artifact: Data? = nil,
        transformProof: (inout [String: Any]) -> Void = { _ in }) throws {
        let root = f.vm.appendingPathComponent(".firmware-history/" + id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var journal = try FirmwareTransaction.readJournal(at: root.appendingPathComponent("journal.json"))
        var publication = try JSONDecoder().decode(FirmwareTransaction.ComponentPublication.self, from: Data(contentsOf: root.appendingPathComponent("component-receipts.json")))
        var proof = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("installed-component-proof.json"))) as? [String: Any])
        if let artifact {
            let payload = try VPhoneKernelcacheSwap.rollbackArtifactPayload(artifact)
            try artifact.write(to: root.appendingPathComponent(FirmwareKernelHistory.artifactName))
            proof["im4pSHA256"] = VPhoneCreateDigest.sha256(artifact); proof["payloadSHA256"] = VPhoneCreateDigest.sha256(payload)
            let old = try JSONDecoder().decode(PatchRunReport.self, from: Data(contentsOf: root.appendingPathComponent("report.json")))
            var first = true
            let components = old.components.map { component in
                ComponentReport(component: component.component, coverage: component.coverage, results: component.results,
                    records: component.records.map { record in
                        let original = first ? Data([0]) : Data([3]); first = false
                        return PatchRecord(patchID: record.patchID, component: record.component, fileOffset: 0,
                            originalBytes: original, patchedBytes: Data([3]), description: "forged but self-consistent history")
                    })
            }
            let report = PatchRunReport(variant: old.variant, gates: old.gates, components: components, ablation: [])
            let bytes = try encoder.encode(report)
            try bytes.write(to: root.appendingPathComponent("report.json")); journal.reportSHA256 = VPhoneCreateDigest.sha256(bytes)
            let receipt = try #require(publication.installed)
            publication.installed = .init(schemaVersion: receipt.schemaVersion, component: receipt.component, scope: receipt.scope,
                state: receipt.state, generationID: receipt.generationID, planSHA256: receipt.planSHA256, desiredSHA256: receipt.desiredSHA256,
                outputs: receipt.outputs, effects: zip(receipt.effects, report.allRecords).map { .init(declarationID: $0.0.declarationID, outputPath: $0.0.outputPath, record: $0.1) })
        }
        transformProof(&proof)
        let proofBytes = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
        try proofBytes.write(to: root.appendingPathComponent("installed-component-proof.json"))
        publication.originProofSHA256 = VPhoneCreateDigest.sha256(proofBytes)
        let bytes = try encoder.encode(publication)
        try bytes.write(to: root.appendingPathComponent("component-receipts.json")); journal.componentReceiptsSHA256 = VPhoneCreateDigest.sha256(bytes)
        journal.metadata = journal.metadata?.map { .init(name: $0.name, original: $0.original,
            output: $0.name == FirmwareTransaction.ComponentPublication.filename ? VPhoneCreateDigest.sha256(bytes) : $0.output) }
        try encoder.encode(journal).write(to: root.appendingPathComponent("journal.json"))
    }

    @Test func selfConsistentForgedHistoryCannotReplaceFreshActualOutput() throws {
        let f = try Fixture(), id = try f.update()
        var forged = Data(repeating: 0, count: 256); forged[0] = 3
        try Self.rewriteHistory(f, id: id, artifact: KernelcacheMetadataTests.source(forged))
        // Historical selection alone is insufficient: production must reproduce
        // the target's exact payload and complete IM4P using the verified source.
        _ = try FirmwareKernelHistory.read(in: f.vm, transactionID: id)
        let prepared = try FirmwareKernelRollback.prepare(in: f.vm, transactionID: id)
        let before = try Data(contentsOf: f.disk)
        #expect(throws: (any Error).self) { try f.rollback(prepared) }
        #expect(try Data(contentsOf: f.disk) == before)
        _ = try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in })
    }

    @Test(arguments: ["old-v8", "other-producer", "other-code", "other-vm", "non-kernel", "link", "hardlink", "uuid"])
    func targetSelectionRefusesUnsupportedAssociation(_ fault: String) throws {
        let f = try Fixture(), id = try f.update()
        if fault == "old-v8" { try Self.rewriteHistory(f, id: id) { $0.removeValue(forKey: "rollbackProtocol") } }
        if fault == "other-producer" { try Self.rewriteHistory(f, id: id) { $0["version"] = "2.6.3" } }
        if fault == "other-code" { try Self.rewriteHistory(f, id: id) { $0["executableSHA256"] = String(repeating: "a", count: 64) } }
        if fault == "non-kernel" {
            let plan = try f.desired().plan
            let entry = try #require(plan.selected.first { !$0.required && !$0.swiftSteps.isEmpty && !$0.swiftSteps.contains(where: { $0.hasPrefix("kernelcache.") }) })
            let blocked = try VariantPlanResolver.resolve(variant: .regular, gates: plan.gates, block: [entry.id])
            let candidate = try FirmwareDesiredPlanStore.prepare(in: f.vm, plan: blocked, generation: f.firmware.generation)
            _ = try FirmwareDesiredPlanStore.publish(candidate, expectedSHA256: candidate.expectedSHA256)
        }
        if fault == "link" || fault == "hardlink" {
            let artifact = f.vm.appendingPathComponent(".firmware-history/" + id + "/" + FirmwareKernelHistory.artifactName)
            let other = f.vm.appendingPathComponent("linked-artifact")
            try FileManager.default.moveItem(at: artifact, to: other)
            if fault == "link" { try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: other) }
            else { try FileManager.default.linkItem(at: other, to: artifact) }
        }
        if fault == "other-vm" {
            let second = try Fixture()
            try FileManager.default.createDirectory(at: second.vm.appendingPathComponent(".firmware-history"), withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: f.vm.appendingPathComponent(".firmware-history/" + id), to: second.vm.appendingPathComponent(".firmware-history/" + id))
            #expect(throws: (any Error).self) { try FirmwareKernelRollback.prepare(in: second.vm, transactionID: id) }
        } else if fault == "other-code" {
            let prepared = try FirmwareKernelRollback.prepare(in: f.vm, transactionID: id)
            #expect(throws: (any Error).self) { try f.rollback(prepared) }
        } else {
            #expect(throws: (any Error).self) { try FirmwareKernelRollback.prepare(in: f.vm, transactionID: fault == "uuid" ? "../" + id : id) }
        }
        if fault == "old-v8" {
            let listed = try FirmwareKernelRollback.targets(in: f.vm)
            #expect(listed.count == 1 && !listed[0].eligible)
            #expect(listed[0].reason?.contains("supported rollback evidence protocol") == true)
        }
    }

    @Test(arguments: ["missing-selection", "schema3-selection", "target-desired", "live-desired", "binding-cas"])
    func schema4RequiresTypedDualPlanContract(_ fault: String) throws {
        let f = try Fixture(), target = try f.update()
        try f.select(force: true); _ = try f.update()
        let prepared = try FirmwareKernelRollback.prepare(in: f.vm, transactionID: target)
        try f.rollback(prepared)
        let path = f.vm.appendingPathComponent(".firmware-history/" + (try f.currentTransaction()) + "/journal.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var selection = try #require(object["rollbackSelection"] as? [String: Any])
        if fault == "missing-selection" { object.removeValue(forKey: "rollbackSelection") }
        if fault == "schema3-selection" { object["version"] = 3 }
        if fault == "target-desired" { object["options"] = ["variant": "regular", "generationID": f.firmware.generation.id, "desiredSHA256": prepared.liveDesiredSHA256] }
        if fault == "live-desired" { selection["liveDesiredSHA256"] = "invalid"; object["rollbackSelection"] = selection }
        if fault == "binding-cas" { selection["bindingSHA256"] = "invalid"; object["rollbackSelection"] = selection }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path)
        #expect(throws: (any Error).self) { try FirmwareTransaction.readJournal(at: path) }
    }

    @Test(arguments: ["complzss", "bvx2", "bvxn"])
    func unknownEncodedArtifactIsRefusedBeforeVendorDecoder(_ prefix: String) throws {
        let artifact = KernelcacheMetadataTests.source(Data(prefix.utf8) + Data(repeating: 0, count: 64))
        #expect(throws: (any Error).self) { try VPhoneKernelcacheSwap.rollbackArtifactPayload(artifact) }
    }
}

extension FirmwareKernelRollbackTests {
    @Test func candidateEnvelopeChangeCannotBecomeCommittedKernel() throws {
        let f = try Fixture(), target = try f.update()
        try f.select(force: true); _ = try f.update()
        let prepared = try FirmwareKernelRollback.prepare(in: f.vm, transactionID: target)
        var operations = f.operations()
        let volumes = operations.volumes
        operations.volumes = { transaction, writable in
            let original = volumes(transaction, writable)!
            return .init(attach: original.attach, inspect: original.inspect, detach: { attachment in
                try original.detach(attachment)
                if writable {
                    var disk = try Data(contentsOf: attachment.image)
                    let im4p = try IMG4(Fixture.image(in: disk)).im4p().data
                    Fixture.setImage(KernelcacheSwapTests.target(im4p, manifest: Data([9, 9, 9])), in: &disk)
                    try disk.write(to: attachment.image)
                }
            })
        }
        let before = try Data(contentsOf: f.disk)
        #expect(throws: (any Error).self) { try f.rollback(prepared, operations: operations) }
        #expect(try Data(contentsOf: f.disk) == before)
        _ = try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in })
    }

    @Test func unknownExternalDiskChangeBlocksRollbackRecovery() throws {
        let f = try Fixture(), target = try f.update()
        try f.select(force: true); _ = try f.update()
        let prepared = try FirmwareKernelRollback.prepare(in: f.vm, transactionID: target)
        var operations = f.operations(), fired = false
        operations.inject = { event in
            if event == .afterPublish("Disk.img") && !fired {
                fired = true
                var disk = try Data(contentsOf: f.disk); disk[8192] = 99; try disk.write(to: f.disk)
                throw POSIXError(.EINTR)
            }
        }
        #expect(throws: (any Error).self) { try f.rollback(prepared, operations: operations) }
        #expect(fired)
        let unknown = try Data(contentsOf: f.disk)
        #expect(throws: (any Error).self) { try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) }
        #expect(try Data(contentsOf: f.disk) == unknown)
        #expect(FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(".firmware-transaction").path))
    }
}

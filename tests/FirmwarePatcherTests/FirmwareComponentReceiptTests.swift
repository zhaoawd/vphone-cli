import Foundation
import Img4tool
import Testing
import VPhoneCore
@testable import FirmwarePatcher

@Suite struct FirmwareComponentReceiptTests {
    @Test func kernelReceiptDoesNotAdvanceBootChain() throws {
        let binding = try VPhoneMachineBinding(bundle: "2.6.1", guestEnvironment: "2.6.0", bootChain: "2.5.0")
        let next = try binding.replacingOrigin(.kernel, with: "2.6.2")
        #expect(next.kernel == "2.6.2")
        #expect(next.bootChain == "2.5.0")
        #expect(next.guestEnvironment == "2.6.0")
        #expect(next.bundle == "2.6.1")
    }

    @Test func guestReceiptDoesNotAdvanceKernel() throws {
        let binding = try VPhoneMachineBinding(bundle: "2.6.1", kernel: "2.5.0")
        let next = try binding.replacingOrigin(.guestEnvironment, with: "2.6.2")
        #expect(next.guestEnvironment == "2.6.2")
        #expect(next.kernel == "2.5.0")
        #expect(next.bootChain == nil)
        #expect(next.bundle == "2.6.1")
    }
}

extension FirmwareComponentReceiptTests {
    struct Fixture {
        let generationFixture: FirmwareGenerationTests.Fixture
        let generation: FirmwareGeneration.Manifest
        let plan: VariantPlanResolver.VariantPlan
        var vm: URL { generationFixture.vm }
        var file: URL { vm.appendingPathComponent("AVPBooter.vresearch1.bin") }
        init(variant: FirmwarePipeline.Variant = .regular, kernelInput: Data? = nil) throws {
            generationFixture = try FirmwareGenerationTests.Fixture()
            if let kernelInput {
                let source = try generationFixture.source()
                let restore = try #require(source.originals.first { $0.name.contains("Restore") })
                try kernelInput.write(to: generationFixture.vm.appendingPathComponent(restore.name + "/kernelcache.research.vphone600"))
                let machine = generationFixture.vm
                let synthetic = FirmwareGeneration.Source(provenance: source.provenance,
                    originals: try source.originals.map { .init(name: $0.name, sha256: try FirmwareGeneration.treeDigest(machine.appendingPathComponent($0.name))) },
                    directory: generationFixture.vm)
                generation = try FirmwareGeneration.publish(generationFixture.prepare(synthetic), planSHA256: generationFixture.planA)
            } else {
                generation = try generationFixture.publish()
            }
            plan = try FirmwarePipeline(vmDirectory: generationFixture.vm, variant: variant, verbose: false).resolvedPlan()
            let desired = try FirmwareDesiredPlanStore.prepare(in: generationFixture.vm, plan: plan, generation: generation)
            _ = try FirmwareDesiredPlanStore.publish(desired, expectedSHA256: nil)
        }
        var patch: PatchRecord {
            PatchRecord(patchID: "avpbooter.dgst_bypass", component: "AVPBooter", fileOffset: 1,
                        originalBytes: Data([0]), patchedBytes: Data([42]), description: "fixture effect")
        }
        func capture(_ records: [PatchRecord]) throws -> FirmwareComponentReceipt.Record {
            try FirmwareComponentReceipt.capture(component: "AVPBooter", plan: plan, generation: generation,
                                                 records: records, outputs: [file])
        }
    }
    @Test func actualPublishedBytesAreReadBack() throws {
        let f = try Fixture()
        try Data([0, 42, 0]).write(to: f.file)
        let receipt = try f.capture([f.patch])
        try FirmwareComponentReceipt.verify(receipt, in: f.vm)
        try Data([0, 0, 0]).write(to: f.file)
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.verify(receipt, in: f.vm) }
    }
    @Test func receiptReadsDecodedIM4PPayload() throws {
        let f = try Fixture()
        try IM4P(fourcc: "illb", description: "synthetic", payload: Data([0, 42, 0])).data.write(to: f.file)
        let receipt = try f.capture([f.patch])
        try FirmwareComponentReceipt.verify(receipt, in: f.vm)
        try IM4P(fourcc: "illb", description: "synthetic", payload: Data([0, 0, 0])).data.write(to: f.file)
        #expect(throws: (any Error).self) { try f.capture([f.patch]) }
    }
    @Test func missingRecordCannotPublishReceipt() throws {
        let f = try Fixture()
        try Data([0, 42, 0]).write(to: f.file)
        #expect(throws: (any Error).self) { try f.capture([]) }
    }
    @Test func laterWriterCannotEraseEarlierRequiredEffect() throws {
        let f = try Fixture()
        try Data([0, 43, 0]).write(to: f.file)
        let later = PatchRecord(patchID: f.patch.patchID, component: f.patch.component, fileOffset: 1,
            originalBytes: Data([42]), patchedBytes: Data([43]), description: "overwritten effect")
        #expect(throws: (any Error).self) { try f.capture([f.patch, later]) }
    }
}

extension FirmwareComponentReceiptTests {
    @Test func manifestPathAndDigestEffectsSurviveReserialization() throws {
        func plist(_ value: [String: Any], _ format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
        }
        let original = try plist(["OS": ["Path": "old.aea", "Digest": Data([0])]])
        let intermediate = try plist(["OS": ["Path": "new.aea", "Digest": Data([0])]])
        let final = try plist(["OS": ["Path": "new.aea", "Digest": Data([1])]], .binary)
        let path = PatchRecord(patchID: "filesystem.cryptex.merge", component: "Filesystem", fileOffset: 0,
                              originalBytes: original, patchedBytes: intermediate, description: "path effect")
        let digest = PatchRecord(patchID: "manifest.hash", component: "Manifest", fileOffset: 0,
                                originalBytes: intermediate, patchedBytes: final, description: "digest effect")
        try FirmwareComponentReceipt.verifyEffect(path, payload: final)
        try FirmwareComponentReceipt.verifyEffect(digest, payload: final)
        let lost = try plist(["OS": ["Path": "old.aea", "Digest": Data([1])]])
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.verifyEffect(path, payload: lost) }
    }
}

extension FirmwareComponentReceiptTests {
    @Test func qualifiedFinalFilesystemReaderReadsCandidateAndDetaches() throws {
        let f = try Fixture()
        let desired = try #require(try FirmwareDesiredPlanStore.read(in: f.vm).readyRecord)
        let transaction = try FirmwareTransaction(vmDirectory: f.vm,
            inputs: f.generation.content.originals.map { f.vm.appendingPathComponent($0.name) },
            options: ["variant": f.plan.variant, "generationID": f.generation.id, "desiredSHA256": try desired.sha256],
            plan: f.plan, versionInputs: FirmwareVersionInputs.read(in: f.vm), mounts: { _, _ in })
        let image = transaction.stage.appendingPathComponent(f.file.lastPathComponent)
        let decrypted = transaction.work.appendingPathComponent("decrypted.dmg")
        let mount = transaction.work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let reader = try FirmwareFilesystemReadback(image: image, expectedSHA256: FirmwareGeneration.fileSHA256(image), transaction: transaction)
        var detachCount = 0
        let operations = FirmwareFilesystemReadback.Operations(decrypt: { source in
            if FileManager.default.fileExists(atPath: decrypted.path) { try FileManager.default.removeItem(at: decrypted) }
            try FileManager.default.copyItem(at: source, to: decrypted)
            return decrypted
        }, attach: { image in
            .init(image: image, device: "synthetic-owned-device", mount: mount, readOnly: true)
        }, detach: { _ in detachCount += 1 })
        let value = try reader.withReadOnlyFilesystem(at: image, transaction: transaction, operations: operations) { actual in
            #expect(actual == mount)
            return 42
        }
        #expect(value == 42)
        #expect(detachCount == 1)
        try Data("wrong image".utf8).write(to: image)
        #expect(throws: (any Error).self) {
            try reader.withReadOnlyFilesystem(at: image, transaction: transaction, operations: operations) { _ in 0 }
        }
        #expect(detachCount == 1)
    }
}

private extension FirmwareDesiredPlanStore.Read {
    var readyRecord: FirmwareDesiredPlanStore.Record? {
        if case .ready(let record) = self { return record }
        return nil
    }
}

extension FirmwareComponentReceiptTests {
    @Test func finalEncryptedImageIncludesLastPlaintextMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let plaintext = root.appendingPathComponent("plain")
        let encrypted = root.appendingPathComponent("encrypted")
        try Data("before cleanup".utf8).write(to: plaintext)
        try CryptexFilesystemPatcher.finalizeImage(prepare: {
            try Data("after cleanup and seal".utf8).write(to: plaintext)
        }, encrypt: {
            try FileManager.default.copyItem(at: plaintext, to: encrypted)
        }, verify: {
            let actual = try Data(contentsOf: encrypted)
            #expect(actual == Data("after cleanup and seal".utf8))
        })
    }
}

extension FirmwareComponentReceiptTests {
    @Test(arguments: ["readonly", "image", "mount", "detach", "body", "replacement", "desired", "disk"])
    func finalFilesystemReaderRefusesFaults(_ fault: String) throws {
        let f = try Fixture()
        let desired = try #require(try FirmwareDesiredPlanStore.read(in: f.vm).readyRecord)
        let t = try FirmwareTransaction(vmDirectory: f.vm,
            inputs: f.generation.content.originals.map { f.vm.appendingPathComponent($0.name) },
            options: ["variant": f.plan.variant, "generationID": f.generation.id, "desiredSHA256": try desired.sha256],
            plan: f.plan, versionInputs: FirmwareVersionInputs.read(in: f.vm), mounts: { _, _ in })
        let image = t.stage.appendingPathComponent(f.file.lastPathComponent)
        let decrypted = t.work.appendingPathComponent("decrypted")
        let mount = t.work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let reader = try FirmwareFilesystemReadback(image: image, expectedSHA256: FirmwareGeneration.fileSHA256(image), transaction: t)
        if fault == "desired" {
            let path = f.vm.appendingPathComponent(".firmware-desired-plan.json")
            var bytes = try Data(contentsOf: path); bytes.append(10); try bytes.write(to: path)
        }
        if fault == "disk" { try Data("replaced disk".utf8).write(to: f.generationFixture.disk, options: .atomic) }
        struct Injected: Error {}
        var detached = 0
        let operations = FirmwareFilesystemReadback.Operations(decrypt: { source in
            try FileManager.default.copyItem(at: source, to: decrypted); return decrypted
        }, attach: { supplied in
            .init(image: fault == "image" ? f.file : supplied, device: "owned-device",
                  mount: fault == "mount" ? f.vm : mount, readOnly: fault != "readonly")
        }, detach: { _ in detached += 1; if fault == "detach" { throw Injected() } })
        #expect(throws: (any Error).self) {
            try reader.withReadOnlyFilesystem(at: image, transaction: t, operations: operations) { _ in
                if fault == "body" { throw Injected() }
                if fault == "replacement" { try Data("replaced encrypted image".utf8).write(to: image) }
            }
        }
        let refusedBeforeDecrypt = fault == "desired" || fault == "disk"
        #expect(detached == (refusedBeforeDecrypt ? 0 : 1))
        #expect(FileManager.default.fileExists(atPath: decrypted.path) == !refusedBeforeDecrypt)
    }

    @Test func mountAssociationMustBeUniqueAndExact() throws {
        let attachment = FirmwareFilesystemReadback.Attachment(image: URL(fileURLWithPath: "/private/expected.dmg"),
            device: "/dev/disk999s1", mount: URL(fileURLWithPath: "/private/owned/mount"), readOnly: true)
        let entry: [String: Any] = ["image-path": attachment.image.path, "system-entities": [
            ["dev-entry": attachment.device, "mount-point": attachment.mount.path]]]
        func data(_ images: [[String: Any]]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)
        }
        try FirmwareFilesystemReadback.verifyAssociation(attachment, info: data([entry]))
        #expect(throws: (any Error).self) { try FirmwareFilesystemReadback.verifyAssociation(attachment, info: data([entry, entry])) }
        var wrong = entry; wrong["image-path"] = "/private/other.dmg"
        #expect(throws: (any Error).self) { try FirmwareFilesystemReadback.verifyAssociation(attachment, info: data([wrong])) }
    }
}


extension FirmwareComponentReceiptTests {
    @Test func deviceTreeEffectsUseDeclaredPropertyIdentityAfterReserialization() throws {
        func node(_ name: String, _ properties: [(String, Data)], children: [Data] = []) -> Data {
            var result = Data()
            let props = [("name", Data((name + "\0").utf8))] + properties
            for count in [props.count, children.count] {
                var value = UInt32(count).littleEndian
                result.append(Data(bytes: &value, count: 4))
            }
            for (key, bytes) in props {
                result.append(Data(key.utf8)); result.append(Data(repeating: 0, count: 32-key.utf8.count))
                var size = UInt32(bytes.count).littleEndian
                result.append(Data(bytes: &size, count: 4)); result.append(bytes)
                result.append(Data(repeating: 0, count: (4-bytes.count%4)%4))
            }
            for child in children { result.append(child) }
            return result
        }
        let expected = Data("vphone-1337\0".utf8)
        let record = PatchRecord(patchID: "devicetree.serial_number", component: "DeviceTree", fileOffset: 1,
                                 originalBytes: Data(), patchedBytes: expected, description: "ignored")
        let final = node("device-tree", [("padding", Data(repeating: 1, count: 16)), ("serial-number", expected)])
        try FirmwareComponentReceipt.verifyEffect(record, payload: final)
        let lost = node("device-tree", [("serial-number", Data(repeating: 0, count: 12))])
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.verifyEffect(record, payload: lost) }
        let duplicate = node("device-tree", [("serial-number", expected), ("serial-number", expected)])
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.verifyEffect(record, payload: duplicate) }
        let added = node("camera", [("arbitrary", Data([1]))])
        let addition = PatchRecord(patchID: "devicetree.product.camera_node", component: "DeviceTree", fileOffset: 0,
                                  originalBytes: Data(), patchedBytes: added, description: "ignored")
        let base = node("device-tree", [], children: [node("product", [])])
        let producer = DeviceTreePatcher(data: base, verbose: false, includeIdentityPatches: true)
        let step = try #require(producer.buildSteps().first { $0.id.method == "product.camera_node" })
        _ = step.run()
        let emitted = try #require(producer.emittedRecords.first)
        producer.commit(producer.emittedRecords)
        try FirmwareComponentReceipt.verifyEffect(emitted, payload: producer.patchedData)
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.verifyEffect(emitted, payload: base) }
        // Incomplete node evidence cannot acquire proof from a declared identity.
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.verifyEffect(addition, payload: final) }
    }
}

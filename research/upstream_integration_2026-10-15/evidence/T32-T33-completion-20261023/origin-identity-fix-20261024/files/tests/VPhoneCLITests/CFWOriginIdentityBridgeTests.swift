import CryptoKit
import Foundation
import Testing
import VPhoneCore
@testable import FirmwarePatcher
@testable import vphone_cli

@Suite struct CFWOriginIdentityBridgeTests {
    @Test(arguments: ["source", "invalidation"])
    func sourceQualifiedPublicationRemainsReadableForFileUndo(mode: String) throws {
        let f = try FirmwareGenerationTestsFixture()
        let context = try VPhoneCFWFrozenContext.prepare(in: f.vm, requestedVariant: nil,
            guestEnvironment: "classic", spoofBuild: "")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let verifier = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VPHONE_TEST_CLI"] ?? root.appendingPathComponent(".build/debug/vphone-cli").path)
        var object = try #require(JSONSerialization.jsonObject(with: Data(context.json.utf8)) as? [String: Any])
        object["verifierPath"] = verifier.path
        object["verifierSHA256"] = SHA256.hash(data: try Data(contentsOf: verifier)).map { String(format: "%02x", $0) }.joined()
        var env = ProcessInfo.processInfo.environment.merging(try context.environment) { _, new in new }
        env["VPHONE_TEST_ORIGIN_IDENTITY_MODE"] = mode
        env["VPHONE_FROZEN_CONTEXT"] = String(decoding: try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let python = root.appendingPathComponent(".venv/bin/python3")
        let result = try VPhoneProcessRunner.runCapturing(python, [root.appendingPathComponent("scripts/vm_lock.py").path,
            f.vm.path, "cfw-record", "--", python.path,
            root.appendingPathComponent("tests/cfw_origin_identity_bridge_fixture.py").path, f.vm.path], env: env)
        let archive = try #require(FileManager.default.contentsOfDirectory(at: f.vm.appendingPathComponent(".cfw-history"),
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasSuffix("fileidentity1") })
        let journal = try JSONDecoder().decode(FirmwareGuestDiskIdentity.Journal.self,
            from: Data(contentsOf: archive.appendingPathComponent("transaction.json")))
        let identity = try JSONDecoder().decode(VPhoneFirmwareIdentity.self,
            from: JSONSerialization.data(withJSONObject: try #require(object["identity"])))
        let checkpoint = try JSONDecoder().decode(FirmwareGuestDiskIdentity.Checkpoint.self,
            from: Data(contentsOf: archive.appendingPathComponent("guest-publication.json")))
        let archives = try FileManager.default.contentsOfDirectory(at: f.vm.appendingPathComponent(".cfw-history"), includingPropertiesForKeys: nil)
        let image = try #require(([f.vm.appendingPathComponent("Disk.img")] + archives.map { $0.appendingPathComponent("Disk.img") }).first {
            guard let info = try? FirmwareGuestDiskIdentity.fileInfo($0) else { return false }
            return checkpoint.runtimeIdentity?.matches(info) == true
        })
        let diskInfo = try FirmwareGuestDiskIdentity.fileInfo(image)
        #expect(checkpoint.runtimeIdentity?.matches(diskInfo) == true)
        #expect(checkpoint.postimageIdentity?.matches(try FirmwareGuestDiskIdentity.fileInfo(
            archive.appendingPathComponent("guest-postimage.img"))) == true)
        #expect(checkpoint.imageSHA256 == (try FirmwareGeneration.fileSHA256(archive.appendingPathComponent("guest-postimage.img"))))
        let plan = try JSONDecoder().decode(FirmwareDesiredPlanStore.Record.self,
            from: Data(contentsOf: archive.appendingPathComponent("guest-plan.json")))
        #expect(plan.identity == identity && plan.generationID == context.generationID)
        if mode == "source" {
            #expect(checkpoint.files["guest-origin-source.json"] != nil)
            #expect(checkpoint.files["guest-origin-transition.json"] != nil)
            #expect(checkpoint.files["guest-origin-attestation.json"] != nil)
        } else {
            #expect(checkpoint.files["guest-origin-invalidation.json"] != nil)
        }
        _ = try FirmwareGuestDiskIdentity.verify(archive: archive, journal: journal,
            image: image, expected: identity, generationID: context.generationID)
        if mode == "source" { try rejectChangedSourceBindings(archive: archive, files: checkpoint.files) }
        for name in checkpoint.files.keys.filter({ $0.hasPrefix("guest-origin-") }) {
            let file = archive.appendingPathComponent(name)
            let saved = try Data(contentsOf: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try Data("changed sealed source".utf8).write(to: file)
            #expect(throws: (any Error).self) {
                try FirmwareGuestDiskIdentity.verify(archive: archive, journal: journal,
                    image: image, expected: identity, generationID: context.generationID)
            }
            try saved.write(to: file)
        }
        try #require(result.succeeded, Comment(rawValue: result.stdout + result.stderr))
        guard case .ready(let record) = try FirmwareDesiredPlanStore.read(in: f.vm) else {
            Issue.record("Source-qualified publication lost the generation binding"); return
        }
        #expect(record.generationID == context.generationID)
    }

    func rejectChangedSourceBindings(archive: URL, files: [String: String]) throws {
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: archive.appendingPathComponent("transaction.json"))) as? [String: Any])
        let keys = ["guestOriginSourceSHA256", "guestOriginTransitionSHA256", "guestOriginAttestationSHA256"]
        let decode: ([String: Any]) throws -> FirmwareGuestDiskIdentity.Journal = {
            try JSONDecoder().decode(FirmwareGuestDiskIdentity.Journal.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        for key in keys {
            var changed = original
            changed.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try FirmwareGuestDiskIdentity.originEvidenceFiles(journal: decode(changed), files: files) }
            changed = original; changed[key] = String(repeating: "e", count: 64)
            #expect(throws: (any Error).self) { try FirmwareGuestDiskIdentity.originEvidenceFiles(journal: decode(changed), files: files) }
        }
        for (key, value) in [("version", 4 as Any), ("operation", "guest-component-undo-v2" as Any),
                             ("guestOriginInvalidationSHA256", String(repeating: "e", count: 64) as Any)] {
            var changed = original; changed[key] = value
            #expect(throws: (any Error).self) { try FirmwareGuestDiskIdentity.originEvidenceFiles(journal: decode(changed), files: files) }
        }
        var invalidation = original
        for key in keys { invalidation.removeValue(forKey: key) }
        let digest = String(repeating: "d", count: 64)
        invalidation["guestOriginInvalidationSHA256"] = digest
        #expect(try FirmwareGuestDiskIdentity.originEvidenceFiles(journal: decode(invalidation),
            files: ["guest-origin-invalidation.json": digest]) == ["guest-origin-invalidation.json"])
        #expect(throws: (any Error).self) { try FirmwareGuestDiskIdentity.originEvidenceFiles(journal: decode(invalidation), files: [:]) }
    }

    final class FirmwareGenerationTestsFixture {
        let vm: URL
        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cfw-origin-identity-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            vm = directory.standardizedFileURL.resolvingSymlinksInPath()
            let restore = vm.appendingPathComponent("iPhone17,3_26.1_23B85_Restore")
            try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 64).write(to: vm.appendingPathComponent("AVPBooter.vresearch1.bin"))
            try Data("synthetic disk".utf8).write(to: vm.appendingPathComponent("Disk.img"))
            // Reuse the normal test machine configuration through the framework.
            try Self.config().write(to: vm.appendingPathComponent("config.plist"))
            for name in ["iPhone-BuildManifest.plist", "BuildManifest.plist"] {
                try PropertyListSerialization.data(fromPropertyList: ["ProductVersion": "26.1", "ProductBuildVersion": "23B85",
                    "BuildIdentities": [["Info": ["Variant": "Customer Erase Install (IPSW)"],
                        "Manifest": ["OS": ["Info": ["Path": "SystemOS.dmg"]]]]]], format: .xml, options: 0)
                    .write(to: restore.appendingPathComponent(name))
            }
            try Data("generation SystemOS fixture".utf8).write(to: restore.appendingPathComponent("SystemOS.dmg"))
            let pipeline = FirmwarePipeline(vmDirectory: vm, variant: .exp, verbose: false, guestEnvironmentV2: false)
            let plan = try pipeline.resolvedPlan(), inputs = try pipeline.transactionRoots()
            let source = FirmwareGeneration.Source(provenance: .init(recognition: "fresh-local-ipsw-prepare-v1",
                inputManifestSHA256: [:], archiveSHA256: [:], builds: [:], device: "synthetic-test", gpuInputs: [],
                bootROMSHA256: String(repeating: "0", count: 64)), originals: try inputs.map {
                    .init(name: $0.lastPathComponent, sha256: try FirmwareGeneration.treeDigest($0))
                }.sorted { $0.name < $1.name }, directory: vm)
            let generation = try FirmwareGeneration.publish(FirmwareGeneration.prepare(in: vm, inputs: inputs, source: source),
                planSHA256: FirmwareGeneration.planDigest(plan))
            _ = try FirmwareDesiredPlanStore.publish(FirmwareDesiredPlanStore.prepare(in: vm, plan: plan, generation: generation), expectedSHA256: nil)
        }
        deinit { try? FileManager.default.removeItem(at: vm) }
        static func config() throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": VZMacMachineIdentifier().dataRepresentation,
                "diskImage": "Disk.img"], format: .xml, options: 0)
        }
    }
}

import Virtualization

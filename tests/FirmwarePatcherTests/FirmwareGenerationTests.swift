import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareGenerationTests {
    @Test func renamePreservesIdentity() throws {
        let fixture = try FirmwarePlanBindingTests.Fixture()
        _ = try fixture.begin()
        let moved = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        #expect(try FirmwareTransaction.recover(vmDirectory: moved, mounts: { _, _ in }) != nil)
    }

    @Test func diskReplacementInvalidatesGeneration() throws {
        let fixture = try FirmwarePlanBindingTests.Fixture()
        let disk = fixture.root.appendingPathComponent("Disk.img")
        try Data("disk-one".utf8).write(to: disk)
        _ = try fixture.begin()
        try FileManager.default.moveItem(at: disk, to: fixture.root.appendingPathComponent("old-disk"))
        try Data("disk-one".utf8).write(to: disk)
        #expect(throws: (any Error).self) { try fixture.recover() }
    }
}

import VPhoneArchiveKit
import VPhoneCore
import Virtualization

extension FirmwareGenerationTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generation-" + UUID().uuidString)
        var vm: URL { root.appendingPathComponent("vm") }
        var rom: URL { root.appendingPathComponent("rom-source") }
        var disk: URL { vm.appendingPathComponent("Disk.img") }
        let planA = String(repeating: "a", count: 64)
        let planB = String(repeating: "b", count: 64)
        var phone: URL!
        var cloud: URL!
        init() throws {
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
            try Data("disk data".utf8).write(to: disk)
            try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": VZMacMachineIdentifier().dataRepresentation,
                "diskImage": "Disk.img"], format: .xml, options: 0).write(to: vm.appendingPathComponent("config.plist"))
            try Data("original boot rom".utf8).write(to: rom)
            try FileManager.default.copyItem(at: rom, to: vm.appendingPathComponent("AVPBooter.vresearch1.bin"))
            phone = try archive(cloud: false)
            cloud = try archive(cloud: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func archive(cloud: Bool) throws -> URL {
            let tree = root.appendingPathComponent(cloud ? "cloud" : "phone")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            let keys = ["LLB", "iBSS", "iBEC", "iBoot", "Ap,RestoreSecurePageTableMonitor",
                "Ap,RestoreTrustedExecutionMonitor", "Ap,SecurePageTableMonitor", "Ap,TrustedExecutionMonitor",
                "DeviceTree", "RestoreDeviceTree", "SEP", "RestoreSEP", "KernelCache", "RestoreKernelCache",
                "RecoveryMode", "RestoreRamDisk", "RestoreTrustCache", "Ap,SystemVolumeCanonicalMetadata",
                "OS", "StaticTrustCache", "SystemVolume"]
            let components = Dictionary(uniqueKeysWithValues: keys.map { ($0, ["Info": ["Path": "Firmware/test.im4p"]]) })
            let identities: [[String: Any]] = cloud ? ["vresearch101ap", "vphone600ap"].flatMap { device in
                ["Release", "Research"].map { variant in
                    ["Info": ["DeviceClass": device, "Variant": variant], "Manifest": components] as [String: Any]
                }
            } : [["Info": ["DeviceClass": "d47ap", "Variant": "Erase"], "Manifest": components]]
            let manifest: [String: Any] = ["ProductVersion": "26.1", "ProductBuildVersion": cloud ? "23B5046f" : "23B85",
                "SupportedProductTypes": cloud ? ["Cloud"] : ["iPhone17,3"], "ManifestVersion": 1, "BuildIdentities": identities,
                "DeviceMap": [["BoardConfig": cloud ? "vresearch101ap" : "d47ap"]],
                "SupportedProductTypeIDs": ["DFU": [1], "Recovery": [2]], "SystemRestoreImageFileSystems": ["User": "APFS"]]
            for name in ["BuildManifest.plist", "Restore.plist"] {
                try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
                    .write(to: tree.appendingPathComponent(name))
            }
            for path in ["kernelcache.test", "Firmware/test.im4p", "shared.dmg", "Firmware/shared.dmg.trustcache"]
                + ["agx", "all_flash", "ane", "dfu", "pmp"].map({ "Firmware/\($0)/component" }) {
                let url = tree.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((cloud ? "cloud" : "phone").utf8).write(to: url)
            }
            let url = root.appendingPathComponent(cloud ? "cloud.ipsw" : "phone.ipsw")
            try VPhoneArchiveWriter.create(archive: url, from: tree, format: .gnutar)
            return url
        }
        func source() throws -> FirmwareGeneration.Source {
            try FirmwarePreparation.prepareWithSource(iPhone: phone, cloudOS: cloud, bundle: vm, bootROMSource: rom,
                                                       preserveExistingRestore: true).source
        }
        func prepare(_ source: FirmwareGeneration.Source) throws -> FirmwareGeneration.Prepared {
            try FirmwareGeneration.prepare(in: vm, inputs: source.originals.map { vm.appendingPathComponent($0.name) }, source: source)
        }
        func publish() throws -> FirmwareGeneration.Manifest {
            try FirmwareGeneration.publish(prepare(source()), planSHA256: planA)
        }
    }

    @Test func repeatedAndReturnedPlansReuseVerifiedOriginals() throws {
        let f = try Fixture()
        let a = try f.publish()
        let a2 = try FirmwareGeneration.publish(f.prepare(f.source()), planSHA256: f.planA)
        let b = try FirmwareGeneration.publish(f.prepare(f.source()), planSHA256: f.planB)
        let a3 = try FirmwareGeneration.publish(f.prepare(f.source()), planSHA256: f.planA)
        #expect(a.id == a2.id && a.id == b.id && a.id == a3.id)
        let root = f.vm.appendingPathComponent(".firmware-generations/\(a.id)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("plans").path).sorted()
            == [f.planA + ".json", f.planB + ".json"])
        let manifestBytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        #expect(!String(decoding: manifestBytes, as: UTF8.self).contains(f.planA))
        #expect(a.content.source.builds == ["iPhone": "23B85", "cloudOS": "23B5046f"])
        #expect(a.content.source.gpuInputs == ["component"])
    }

    @Test func renamedGenerationLoadsAndNormalDiskWritesPreserveIdentity() throws {
        let f = try Fixture(); let a = try f.publish()
        let handle = try FileHandle(forWritingTo: f.disk)
        try handle.write(contentsOf: Data("normal VM write".utf8)); try handle.close()
        let moved = f.root.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: f.vm, to: moved)
        #expect(try FirmwareGeneration.loadVerified(in: moved, id: a.id) == a)
    }

    @Test func replacementDiskInvalidatesPublishedGeneration() throws {
        let f = try Fixture(); let a = try f.publish()
        try FileManager.default.moveItem(at: f.disk, to: f.root.appendingPathComponent("old-disk"))
        try Data("disk data".utf8).write(to: f.disk)
        #expect(throws: (any Error).self) { try FirmwareGeneration.loadVerified(in: f.vm, id: a.id) }
    }

    @Test(arguments: ["rewrite", "symlink", "hardlink"])
    func badOriginalCannotBecomeSource(_ mutation: String) throws {
        let f = try Fixture(); let source = try f.source()
        let original = f.vm.appendingPathComponent(source.originals.first!.name)
        if mutation == "rewrite" {
            try Data("replaced boot rom".utf8).write(to: original)
        } else {
            try FileManager.default.removeItem(at: original)
            if mutation == "symlink" { try FileManager.default.createSymbolicLink(at: original, withDestinationURL: f.rom) }
            else { try FileManager.default.linkItem(at: f.rom, to: original) }
        }
        #expect(throws: (any Error).self) { try f.prepare(source) }
    }

    @Test func failedNewGenerationPreservesOld() throws {
        let f = try Fixture(); let a = try f.publish()
        let pending = try f.prepare(f.source())
        let original = pending.staging.appendingPathComponent("originals/AVPBooter.vresearch1.bin")
        try Data("replaced boot rom".utf8).write(to: original)
        #expect(throws: (any Error).self) { try FirmwareGeneration.publish(pending, planSHA256: f.planB) }
        #expect(try FirmwareGeneration.loadVerified(in: f.vm, id: a.id) == a)
        try FirmwareGeneration.discard(pending)
    }

    @Test func interruptedAndCancelledGenerationKeepPublishedOriginals() async throws {
        let f = try Fixture(); let a = try f.publish()
        let pending = try f.prepare(f.source())
        // An abandoned .pending directory is never interpreted as published state.
        #expect(try FirmwareGeneration.loadVerified(in: f.vm, id: a.id) == a)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try FirmwareGeneration.publish(pending, planSHA256: String(repeating: "b", count: 64)) }
        }
        await cancelled.value
        #expect(try FirmwareGeneration.loadVerified(in: f.vm, id: a.id) == a)
        try FirmwareGeneration.discard(pending)
    }

    @Test(arguments: ["rewrite", "symlink", "extra"])
    func storedOriginalReadbackRejectsChanges(_ mutation: String) throws {
        let f = try Fixture(); let a = try f.publish()
        let root = f.vm.appendingPathComponent(".firmware-generations/\(a.id)/originals")
        let original = root.appendingPathComponent("AVPBooter.vresearch1.bin")
        if mutation == "rewrite" { try Data("replaced boot rom".utf8).write(to: original) }
        else if mutation == "symlink" {
            try FileManager.default.removeItem(at: original)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: f.rom)
        } else { try Data().write(to: root.appendingPathComponent("extra")) }
        #expect(throws: (any Error).self) { try FirmwareGeneration.loadVerified(in: f.vm, id: a.id) }
    }

    @Test func legacySourceRequiresIndependentFreshPreparation() throws {
        let f = try Fixture(); let source = try f.source()
        let file = f.vm.appendingPathComponent(source.originals.last!.name + "/Firmware/test.im4p")
        try Data("patch".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            try FirmwarePreparation.verifyPreparedSource(iPhone: f.phone, cloudOS: f.cloud, bundle: f.vm, bootROMSource: f.rom)
        }
        _ = try f.source()
        let verified = try FirmwarePreparation.verifyPreparedSource(iPhone: f.phone, cloudOS: f.cloud, bundle: f.vm, bootROMSource: f.rom)
        #expect(try FirmwareGeneration.publish(f.prepare(verified), planSHA256: f.planA).content.originals == source.originals)
    }

    @Test(arguments: ["missing", "empty", "corrupt", "linked"])
    func invalidMachineIdentityNeverBecomesNilBinding(_ mutation: String) throws {
        let f = try Fixture(); let source = try f.source()
        let config = f.vm.appendingPathComponent("config.plist")
        if mutation == "missing" { try FileManager.default.removeItem(at: config) }
        else if mutation == "linked" {
            let saved = f.root.appendingPathComponent("config")
            try FileManager.default.moveItem(at: config, to: saved)
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: saved)
        } else {
            let machine = mutation == "empty" ? Data() : Data("invalid".utf8)
            try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": machine, "diskImage": "Disk.img"],
                format: .xml, options: 0).write(to: config)
        }
        #expect(throws: (any Error).self) { try f.prepare(source) }
    }
}

extension FirmwareGenerationTests {
    @Test(arguments: ["regular", "less"])
    func realScriptPreparationQualifiesThroughIndependentProducer(_ variant: String) throws {
        let f = try Fixture()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let python = repo.appendingPathComponent(".venv/bin/python")
        let zipScript = """
        import pathlib, sys, zipfile
        root = pathlib.Path(sys.argv[1])
        with zipfile.ZipFile(sys.argv[2], 'w') as archive:
            for path in sorted(root.rglob('*')):
                if path.is_file():
                    archive.write(path, str(path.relative_to(root)))
        """
        let phone = f.root.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        let cloud = f.root.appendingPathComponent("source-cloud.ipsw")
        for (tree, zip) in [("phone", phone), ("cloud", cloud)] {
            let result = try VPhoneProcessRunner.runCapturing(python, ["-c", zipScript, f.root.appendingPathComponent(tree).path, zip.path])
            #expect(result.succeeded, "\(result.stderr)")
        }
        let seal = f.root.appendingPathComponent("seal")
        try FileManager.default.createDirectory(at: seal, withIntermediateDirectories: false)
        // The less producer reuses a local seal tool; this test never mounts a disk or downloads it.
        try Data("fixture-existing-seal-tool".utf8).write(to: seal.appendingPathComponent("apfs_sealvolume_26.1"))
        var env = ProcessInfo.processInfo.environment
        env["VPHONE_PYTHON"] = python.path
        env["IPSW_DIR"] = f.root.appendingPathComponent("cache").path
        env["VPHONE_SEAL_DIR"] = seal.path
        env["VARIANT"] = variant
        env["IPHONE_SOURCE"] = phone.path
        env["CLOUDOS_SOURCE"] = cloud.path
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/bin/bash"),
            [repo.appendingPathComponent("scripts/fw_prepare.sh").path], cwd: f.vm, env: env, timeout: 30)
        #expect(result.succeeded, "\(result.stdout)\n\(result.stderr)")
        let source = try FirmwarePreparation.verifyPreparedSource(iPhone: phone, cloudOS: cloud, bundle: f.vm, bootROMSource: f.rom)
        let manifest = try FirmwareGeneration.publish(f.prepare(source), planSHA256: f.planA)
        #expect(try FirmwareGeneration.loadVerified(in: f.vm, id: manifest.id) == manifest)
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.vm.appendingPathComponent(".firmware-prepare-sources.json"))) as? [String: Any])
        #expect(record["schemaVersion"] as? Int == 1)
        #expect((record["iPhoneArchive"] as? String)?.hasSuffix("iPhone17,3_26.1_23B85_Restore.ipsw") == true)
    }
}

extension FirmwareGenerationTests {
    @Test func distinctSourceGenerationsNeverMixOriginalSets() throws {
        let f = try Fixture(); let a = try f.publish()
        let archiveA = try Data(contentsOf: f.cloud)
        try Data("other".utf8).write(to: f.root.appendingPathComponent("cloud/Firmware/test.im4p"))
        try FileManager.default.removeItem(at: f.cloud)
        try VPhoneArchiveWriter.create(archive: f.cloud, from: f.root.appendingPathComponent("cloud"), format: .gnutar)
        let b = try FirmwareGeneration.publish(f.prepare(f.source()), planSHA256: f.planB)
        #expect(a.id != b.id)
        #expect(try FirmwareGeneration.loadVerified(in: f.vm, id: a.id) == a)
        try archiveA.write(to: f.cloud)
        let returned = try f.publish()
        #expect(returned == a)
        #expect(try FirmwareGeneration.loadVerified(in: f.vm, id: b.id) == b)
    }

    @Test func generationBoundTransactionRejectsOtherOriginals() throws {
        let f = try Fixture(); let a = try f.publish()
        let inputs = a.content.originals.map { f.vm.appendingPathComponent($0.name) }
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: VariantPlanTests.snapshots(.regular)[0])
        let versions = try FirmwareVersionInputs.read(in: inputs.last!)
        let transaction = try FirmwareTransaction(vmDirectory: f.vm, inputs: inputs,
            options: ["variant": "regular", "generationID": a.id], plan: plan, versionInputs: versions, mounts: { _, _ in })
        #expect(transaction.journalSnapshot.planBinding?.payload.generationID == a.id)
        #expect(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }) != nil)
        try Data("replaced boot rom".utf8).write(to: inputs.first!)
        #expect(throws: (any Error).self) {
            try FirmwareTransaction(vmDirectory: f.vm, inputs: inputs,
                options: ["variant": "regular", "generationID": a.id], plan: plan, versionInputs: versions, mounts: { _, _ in })
        }
    }
}

extension FirmwareGenerationTests {
    @Test func capacityPreflightCountsNestedBytesAndRejectsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("a"))
        try Data([4, 5]).write(to: root.appendingPathComponent("nested/b"))
        #expect(try FirmwareGeneration.logicalBytes(root) == 5)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "a")
        #expect(throws: (any Error).self) { try FirmwareGeneration.logicalBytes(root) }
    }
}

extension FirmwareGenerationTests {
    @Test func interruptedPlanAssociationDoesNotBlockRetryOrOverwriteEvidence() throws {
        let f = try Fixture(); let a = try f.publish()
        let plans = f.vm.appendingPathComponent(".firmware-generations/\(a.id)/plans")
        try Data("interrupted write".utf8).write(to: plans.appendingPathComponent(".write-abandoned"))
        let b = try FirmwareGeneration.publish(f.prepare(f.source()), planSHA256: f.planB)
        #expect(b == a)
        let original = try Data(contentsOf: plans.appendingPathComponent(f.planA + ".json"))
        #expect(throws: (any Error).self) { try FirmwareGeneration.write(Data("replacement".utf8), to: plans.appendingPathComponent(f.planA + ".json")) }
        #expect(try Data(contentsOf: plans.appendingPathComponent(f.planA + ".json")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: plans.path).filter { $0.hasPrefix(".write-") } == [".write-abandoned"])
    }
}

extension FirmwareGenerationTests {
    @Test func currentVMROMCannotQualifyItselfAsSource() throws {
        let f = try Fixture()
        let current = f.vm.appendingPathComponent("AVPBooter.vresearch1.bin")
        #expect(throws: (any Error).self) {
            try FirmwarePreparation.prepareWithSource(iPhone: f.phone, cloudOS: f.cloud, bundle: f.vm, bootROMSource: current)
        }
        #expect(throws: (any Error).self) {
            try FirmwarePreparation.verifyPreparedSource(iPhone: f.phone, cloudOS: f.cloud, bundle: f.vm, bootROMSource: current)
        }
    }
}

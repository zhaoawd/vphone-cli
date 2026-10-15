import Foundation
import Testing
import VPhoneCore
@testable import FirmwarePatcher

@Suite struct FirmwareGenerationPreparationTests {
    @Test func libraryDirectoryURLCanPrepareFreshArchives() throws {
        let f = try FirmwareGenerationTests.Fixture()
        let library = VPhoneLibrary(root: URL(fileURLWithPath: f.root.path, isDirectory: true))
        let directory = library.url(forName: "vm")
        let record = try FirmwareGenerationPreparation.prepare(in: directory, iPhone: f.phone,
            cloudOS: f.cloud, bootROMSource: f.rom, variant: .exp)
        #expect(record.identity == (try VPhoneFirmwareIdentity.read(in: f.vm)))
    }

    @Test func freshArchivesBindTargetWithoutChangingInstalledFirmware() throws {
        let f = try FirmwareGenerationTests.Fixture()
        let installed = f.vm.appendingPathComponent("Installed_Restore")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: false)
        try Data("installed patched firmware".utf8).write(to: installed.appendingPathComponent("boot.im4p"))
        let rom = f.vm.appendingPathComponent("AVPBooter.vresearch1.bin")
        try Data("installed patched ROM".utf8).write(to: rom)
        let before = try [f.disk, rom, installed].map { try FirmwareGeneration.treeDigest($0) }
        let identity = try VPhoneFirmwareIdentity.read(in: f.vm)
        let record = try FirmwareGenerationPreparation.prepare(in: f.vm, iPhone: f.phone,
            cloudOS: f.cloud, bootROMSource: f.rom, variant: .regular)
        #expect(try [f.disk, rom, installed].map { try FirmwareGeneration.treeDigest($0) } == before)
        #expect(try VPhoneFirmwareIdentity.read(in: f.vm) == identity)
        #expect(record.identity == identity)
        let generation = try FirmwareGeneration.loadVerified(in: f.vm, id: record.generationID)
        #expect(generation.content.source.recognition == "fresh-local-ipsw-prepare-v1")
        #expect(generation.content.source.archiveSHA256["iPhone"] == (try FirmwareGeneration.fileSHA256(f.phone)))
        #expect(generation.content.source.archiveSHA256["cloudOS"] == (try FirmwareGeneration.fileSHA256(f.cloud)))
        let originals = try FirmwareGeneration.originalURLs(in: f.vm, id: record.generationID)
        let originalROM = try #require(originals.first { $0.lastPathComponent == rom.lastPathComponent })
        #expect(try Data(contentsOf: originalROM) == Data(contentsOf: f.rom))
        #expect(try Data(contentsOf: originalROM) != Data(contentsOf: rom))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.vm.path)
            .allSatisfy { !$0.hasPrefix(".firmware-generation-prepare-") })
        let desiredBytes = try Data(contentsOf: f.vm.appendingPathComponent(FirmwareDesiredPlanStore.filename))
        #expect(throws: (any Error).self) {
            try FirmwareGenerationPreparation.prepare(in: f.vm, iPhone: f.phone,
                cloudOS: f.cloud, bootROMSource: f.rom, variant: .dev)
        }
        #expect(try Data(contentsOf: f.vm.appendingPathComponent(FirmwareDesiredPlanStore.filename)) == desiredBytes)
    }

    @Test func failedArchivePreparationLeavesInstalledBytesAndNoDesiredPlan() throws {
        let f = try FirmwareGenerationTests.Fixture()
        let rom = f.vm.appendingPathComponent("AVPBooter.vresearch1.bin")
        let before = try [f.disk, rom].map { try FirmwareGeneration.treeDigest($0) }
        try Data("invalid archive".utf8).write(to: f.phone)
        #expect(throws: (any Error).self) {
            try FirmwareGenerationPreparation.prepare(in: f.vm, iPhone: f.phone,
                cloudOS: f.cloud, bootROMSource: f.rom, variant: .regular)
        }
        #expect(try [f.disk, rom].map { try FirmwareGeneration.treeDigest($0) } == before)
        guard case .missing = try FirmwareDesiredPlanStore.read(in: f.vm) else {
            Issue.record("Failed preparation published a desired plan"); return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.vm.path)
            .allSatisfy { !$0.hasPrefix(".firmware-generation-prepare-") })
    }

    @Test func rejectsVMROMAsSource() throws {
        let f = try FirmwareGenerationTests.Fixture()
        #expect(throws: (any Error).self) {
            try FirmwareGenerationPreparation.prepare(in: f.vm, iPhone: f.phone,
                cloudOS: f.cloud, bootROMSource: f.vm.appendingPathComponent("AVPBooter.vresearch1.bin"), variant: .regular)
        }
    }

    @Test func refusesBusyVMAndUncertainMetadataBeforePreparing() throws {
        let f = try FirmwareGenerationTests.Fixture()
        do {
            let lock = try VPhoneVMLock(directory: f.vm, operation: "test-generation-preparation")
            defer { withExtendedLifetime(lock) {} }
            #expect(throws: (any Error).self) {
                try FirmwareGenerationPreparation.prepare(in: f.vm, iPhone: f.phone,
                    cloudOS: f.cloud, bootROMSource: f.rom, variant: .regular)
            }
        }
        let pending = f.vm.appendingPathComponent(".firmware-desired-pending.json")
        let evidence = Data("uncertain publication evidence".utf8)
        try evidence.write(to: pending)
        #expect(throws: FirmwareDesiredPlanStore.Failure.publicationUncertain) {
            try FirmwareGenerationPreparation.prepare(in: f.vm, iPhone: f.phone,
                cloudOS: f.cloud, bootROMSource: f.rom, variant: .regular)
        }
        #expect(try Data(contentsOf: pending) == evidence)
        #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(".firmware-generations").path))
    }

    @Test func publicCaptureStillRejectsSourceFromAnotherDirectory() throws {
        let f = try FirmwareGenerationTests.Fixture()
        let source = try f.source()
        let other = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try FirmwareGeneration.prepare(in: other,
                inputs: source.originals.map { f.vm.appendingPathComponent($0.name) }, source: source)
        }
        #expect(throws: (any Error).self) {
            try FirmwareGeneration.prepareFreshSource(in: other, sourceDirectory: f.vm, source: source)
        }
    }
}

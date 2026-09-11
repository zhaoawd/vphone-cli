import CryptoKit
import Darwin
import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareTransactionTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var restore: URL { root.appendingPathComponent("FixtureRestore") }
        var boot: URL { root.appendingPathComponent("AVPBooter.fixture.bin") }
        let fm = FileManager.default
        init() throws {
            try fm.createDirectory(at: restore.appendingPathComponent("Firmware/empty"), withIntermediateDirectories: true)
            try Data("original boot".utf8).write(to: boot)
            try Data("original payload".utf8).write(to: restore.appendingPathComponent("Firmware/payload"))
            try Data("original manifest".utf8).write(to: restore.appendingPathComponent("BuildManifest.plist"))
            // VM runtime data is deliberately outside the transaction.
            try Data("VM disk".utf8).write(to: root.appendingPathComponent("Disk.img"))
        }
        deinit { try? fm.removeItem(at: root) }
        func begin(inject: @escaping (FirmwareTransaction.Event) throws -> Void = { _ in },
                   mounts: @escaping (URL, Bool) throws -> Void = { _, _ in }) throws -> FirmwareTransaction {
            try FirmwareTransaction(vmDirectory: root, inputs: [boot, restore], options: ["variant": "fixture"], inject: inject, mounts: mounts)
        }
        func patch(_ t: FirmwareTransaction) throws {
            try Data("patched boot".utf8).write(to: t.stage.appendingPathComponent(boot.lastPathComponent))
            let r = t.stage.appendingPathComponent(restore.lastPathComponent)
            try fm.removeItem(at: r.appendingPathComponent("Firmware/payload"))
            try Data("new image".utf8).write(to: r.appendingPathComponent("image.aea"))
            try Data("new manifest".utf8).write(to: r.appendingPathComponent("BuildManifest.plist"))
        }
        func recover(inject: @escaping (FirmwareTransaction.Event) throws -> Void = { _ in }) throws -> URL? {
            try FirmwareTransaction.recover(vmDirectory: root, inject: inject, mounts: { _, _ in })
        }
        func original() throws {
            #expect(try Data(contentsOf: boot) == Data("original boot".utf8))
            #expect(try Data(contentsOf: restore.appendingPathComponent("Firmware/payload")) == Data("original payload".utf8))
            #expect(!fm.fileExists(atPath: restore.appendingPathComponent("image.aea").path))
            #expect(try Data(contentsOf: root.appendingPathComponent("Disk.img")) == Data("VM disk".utf8))
        }
    }

    @Test func stagedWritesDoNotAlterOriginalAndCommitPublishesAllFiles() throws {
        let f = try Fixture(); let t = try f.begin(); try f.patch(t); try f.original()
        let archive = try t.commit()
        #expect(try Data(contentsOf: f.boot) == Data("patched boot".utf8))
        #expect(try Data(contentsOf: f.restore.appendingPathComponent("image.aea")) == Data("new image".utf8))
        #expect(!f.fm.fileExists(atPath: f.restore.appendingPathComponent("Firmware/payload").path))
        #expect(try Data(contentsOf: archive.appendingPathComponent("backup/AVPBooter.fixture.bin")) == Data("original boot".utf8))
        #expect(try f.recover() == nil)
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func recoveryHandlesEveryRenameWindow(_ point: Int) throws {
        let f = try Fixture()
        let events: [FirmwareTransaction.Event] = [.beforeBackup(f.boot.lastPathComponent), .afterBackup(f.boot.lastPathComponent),
            .afterPublish(f.boot.lastPathComponent), .afterBackup(f.restore.lastPathComponent), .afterPublish(f.restore.lastPathComponent)]
        let t = try f.begin { if $0 == events[point] { throw POSIXError(.EINTR) } }
        try f.patch(t)
        #expect(throws: (any Error).self) { try t.commit() }
        #expect(try f.recover() != nil)
        try f.original()
        #expect(try f.recover() == nil)
    }

    @Test func repeatedRecoverySurvivesInterruptionDuringRollback() throws {
        let f = try Fixture()
        let t = try f.begin { if $0 == .afterPublish(f.restore.lastPathComponent) { throw POSIXError(.EINTR) } }
        try f.patch(t); #expect(throws: (any Error).self) { try t.commit() }
        #expect(throws: (any Error).self) {
            try f.recover { if $0 == .afterRestore(f.boot.lastPathComponent) { throw POSIXError(.EINTR) } }
        }
        #expect(try f.recover() != nil); try f.original()
    }

    @Test func committedRecoveryDoesNotRollBackSuccessfulPublication() throws {
        let f = try Fixture()
        let t = try f.begin { if $0 == .beforeArchive { throw POSIXError(.EINTR) } }
        try f.patch(t); #expect(throws: (any Error).self) { try t.commit() }
        #expect(try f.recover() != nil)
        #expect(try Data(contentsOf: f.boot) == Data("patched boot".utf8))
    }

    @Test func diskFullWhileCopyingOrPreparingCommitKeepsOriginal() throws {
        for failCopy in [true, false] {
            let f = try Fixture()
            if failCopy {
                #expect(throws: (any Error).self) {
                    try f.begin { if $0 == .beforeCopy(f.restore.lastPathComponent) { throw POSIXError(.ENOSPC) } }
                }
            } else {
                let t = try f.begin { if $0 == .beforeReady { throw POSIXError(.ENOSPC) } }
                try f.patch(t); #expect(throws: (any Error).self) { try t.commit() }
            }
            try f.original(); #expect(try f.recover() != nil); try f.original()
        }
    }

    @Test func externalEditPreventsCommitAndRecoveryWithoutOverwritingIt() throws {
        let f = try Fixture(); let t = try f.begin(); try f.patch(t)
        let external = Data("external edit".utf8); try external.write(to: f.boot)
        #expect(throws: (any Error).self) { try t.commit() }
        #expect(throws: (any Error).self) { try f.recover() }
        #expect(try Data(contentsOf: f.boot) == external)
    }

    @Test func recoveryValidatesAllEntriesBeforeRestoringAny() throws {
        let f = try Fixture()
        let t = try f.begin { if $0 == .afterPublish(f.restore.lastPathComponent) { throw POSIXError(.EINTR) } }
        try f.patch(t); #expect(throws: (any Error).self) { try t.commit() }
        try Data("external edit".utf8).write(to: f.restore.appendingPathComponent("BuildManifest.plist"))
        #expect(throws: (any Error).self) { try f.recover() }
        #expect(try Data(contentsOf: f.boot) == Data("patched boot".utf8))
    }

    @Test func symlinkInputAndOutputAreRejected() throws {
        for beforeStage in [true, false] {
            let f = try Fixture()
            if beforeStage {
                try f.fm.createSymbolicLink(at: f.restore.appendingPathComponent("escape"), withDestinationURL: f.boot)
                #expect(throws: (any Error).self) { try f.begin() }
            } else {
                let t = try f.begin()
                try f.fm.createSymbolicLink(at: t.stage.appendingPathComponent("FixtureRestore/escape"), withDestinationURL: f.boot)
                #expect(throws: (any Error).self) { try t.commit() }
                try f.original()
            }
        }
    }

    @Test func existingTransactionAndActiveToolBlockNewWorkAndRecovery() throws {
        let f = try Fixture(); let t = try f.begin()
        #expect(throws: (any Error).self) { try f.begin() }
        let fd = open(t.root.path, O_RDONLY | O_DIRECTORY)
        #expect(fd >= 0); defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: (any Error).self) { try f.recover() }
        flock(fd, LOCK_UN)
        #expect(try f.recover() != nil)
    }

    @Test func attachedImageFailurePreventsPublication() throws {
        let f = try Fixture()
        let t = try f.begin(mounts: { _, _ in throw POSIXError(.EBUSY) })
        try f.patch(t); #expect(throws: (any Error).self) { try t.commit() }; try f.original()
        #expect(try f.recover() != nil)
    }

    @Test func lessManifestChecksEveryReferencedArtifact() throws {
        let f = try Fixture()
        let payload = Data("payload".utf8)
        let file = f.restore.appendingPathComponent("image.aea"); try payload.write(to: file)
        let manifest: [String: Any] = ["BuildIdentities": [["Manifest": ["OS": [
            "Info": ["Path": "image.aea"], "Digest": Data(SHA384.hash(data: payload))]]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try data.write(to: f.restore.appendingPathComponent("BuildManifest.plist"))
        try FirmwarePipeline.validateManifest(in: f.restore)
        try Data("corrupt".utf8).write(to: file)
        #expect(throws: (any Error).self) { try FirmwarePipeline.validateManifest(in: f.restore) }
    }

    @Test func killedInitializationWithoutJournalCanBeArchived() throws {
        let f = try Fixture()
        try f.fm.createDirectory(at: f.root.appendingPathComponent(".firmware-transaction"), withIntermediateDirectories: false)
        #expect(try f.recover() != nil); try f.original()
    }

    @Test func corruptJournalCannotTriggerAReplacement() throws {
        let f = try Fixture(); let t = try f.begin(); try f.patch(t)
        try Data("invalid journal".utf8).write(to: t.root.appendingPathComponent("journal.json"))
        #expect(throws: (any Error).self) { try f.recover() }; try f.original()
    }

    private struct FailingLoader: FirmwarePipeline.FirmwareLoader {
        let failRead: Bool
        func load(from url: URL) throws -> Data {
            if failRead { throw POSIXError(.EIO) }
            return try Data(contentsOf: url)
        }
        func save(_ data: Data, to url: URL) throws {
            try Data("partial output".utf8).write(to: url)
            throw POSIXError(.ENOSPC)
        }
    }

    @Test(arguments: [true, false]) func pipelineReadAndPartialSaveFailuresRemainRecoverable(_ failRead: Bool) throws {
        let f = try Fixture()
        let pipeline = FirmwarePipeline(vmDirectory: f.root, verbose: false, loader: FailingLoader(failRead: failRead))
        #expect(throws: (any Error).self) {
            try pipeline.patchAllStructured(ablate: ["avpbooter"], allowOutput: true)
        }
        try f.original()
        let journalURL = f.root.appendingPathComponent(".firmware-transaction/journal.json")
        let journal = try JSONDecoder().decode(FirmwareTransaction.Journal.self, from: Data(contentsOf: journalURL))
        #expect(journal.phase == .building)
        #expect(journal.failure != nil)
        #expect(try f.recover() != nil)
        try f.original()
        #expect(try f.recover() == nil)
    }

    @Test func bareAPFSImageResolvesItsPhysicalStore() throws {
        let entries: [[String: Any]] = [
            ["content-hint": "", "dev-entry": "/dev/disk16"],
            ["content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC", "dev-entry": "/dev/disk17"],
            ["content-hint": "41504653-0000-11AA-AA11-00306543ECAC", "dev-entry": "/dev/disk17s1"],
        ]
        let device = try FirmwareTransaction.detachDevice(entries: entries, inspect: { device in
            var info: [String: Any] = ["DeviceNode": device, "BusProtocol": "Disk Image"]
            if device == "/dev/disk17" { info["APFSPhysicalStores"] = [["APFSPhysicalStore": "disk16"]] }
            return info
        })
        #expect(device == "/dev/disk16")
        #expect(throws: (any Error).self) {
            try FirmwareTransaction.detachDevice(entries: entries, inspect: { device in
                ["DeviceNode": device, "BusProtocol": "Disk Image",
                 "APFSPhysicalStores": [["APFSPhysicalStore": "disk99"]]]
            })
        }
    }

    @Test func nativeToolOutputIsDrainedAndClosed() throws {
        let output = try FirmwareTransaction.run("/usr/bin/printf", ["transaction-tool-output"])
        #expect(String(decoding: output, as: UTF8.self) == "transaction-tool-output")
    }
}

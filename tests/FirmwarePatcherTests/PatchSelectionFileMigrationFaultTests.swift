import CryptoKit
import Darwin
import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct PatchSelectionFileMigrationFaultTests {
    struct Injected: Error {}

    func fixture() throws -> (URL, URL, Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selection-fault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let file = dir.appendingPathComponent("PatchSelection.plist")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["Preset": "extended",
            "AllowedPatches": ["ibss.serial_label"], "BlockedPatches": ["kernel-exp-paravirt_user_clients"]], format: .xml, options: 0)
        try bytes.write(to: file)
        return (dir, file, bytes)
    }

    @Test(arguments: [PatchSelectionFileMigration.Event.beforeBackup, .afterBackup, .beforePublish])
    func failureBeforePublicationPreservesSourceAndCleansStage(event: PatchSelectionFileMigration.Event) throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        #expect(throws: Injected.self) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256) {
                switch (event, $0) {
                case (.beforeBackup, .beforeBackup), (.afterBackup, .afterBackup), (.beforePublish, .beforePublish): throw Injected()
                default: break
                }
            }
        }
        #expect(try Data(contentsOf: file) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.hasPrefix(".PatchSelection.plist.migrate-") })
        if case .beforeBackup = event {
            #expect(names == ["PatchSelection.plist"])
        } else {
            let backup = dir.appendingPathComponent("PatchSelection.plist.before-id-migration-\(prepared.preview.sourceSHA256).bak")
            #expect(try Data(contentsOf: backup) == before)
        }
    }

    @Test func retryAfterBackupReusesVerifiedOriginal() throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        #expect(throws: Injected.self) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256) {
                if case .afterBackup = $0 { throw Injected() }
            }
        }
        let result = try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256)
        #expect(result.changed)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(result.backupPath))) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }

    @Test func failureAfterRenameReportsUncertainPublicationAndKeepsBackup() throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        let backup = dir.appendingPathComponent("PatchSelection.plist.before-id-migration-\(prepared.preview.sourceSHA256).bak")
        #expect(throws: PatchSelectionFileMigration.Failure.publicationUncertain(backup: backup.resolvingSymlinksInPath().path)) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256) {
                if case .afterPublish = $0 { throw Injected() }
            }
        }
        #expect(try Data(contentsOf: backup) == before)
        let fields = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        #expect(fields["BlockedPatches"] as? [String] == ["kernel-cfw-paravirt_user_clients"])
    }

    @Test func corruptExistingBackupCannotBeOverwritten() throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        let backup = dir.appendingPathComponent("PatchSelection.plist.before-id-migration-\(prepared.preview.sourceSHA256).bak")
        let unrelated = Data("unrelated file".utf8); try unrelated.write(to: backup)
        #expect(throws: PatchSelectionFileMigration.Failure.backupConflict) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256)
        }
        #expect(try Data(contentsOf: backup) == unrelated)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func sameBytesInReplacementInodeStillInvalidatePreparedOperation() throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        try before.write(to: file, options: .atomic)
        #expect(throws: PatchSelectionFileMigration.Failure.changedSincePreview) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["PatchSelection.plist"])
    }

    @Test func sourceChangedAfterBackupIsPreservedInsteadOfPublishedOver() throws {
        let (dir, file, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        let external = Data("externally changed selection".utf8)
        #expect(throws: PatchSelectionFileMigration.Failure.changedSincePreview) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256) {
                if case .beforePublish = $0 { try external.write(to: file) }
            }
        }
        #expect(try Data(contentsOf: file) == external)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path)).contains { $0.hasPrefix(".PatchSelection.plist.migrate-") })
    }

    @Test func pendingFirmwareTransactionRefusesSelectionWrite() throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".firmware-transaction"), withIntermediateDirectories: false)
        #expect(throws: PatchSelectionFileMigration.Failure.pendingTransaction) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256)
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func hardLinkedSelectionIsRejected() throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("shared.plist")
        #expect(Darwin.link(file.path, link.path) == 0)
        #expect(throws: PatchSelectionFileMigration.Failure.unsafeFile) {
            try PatchSelectionFileMigration.prepare(file: file)
        }
        #expect(try Data(contentsOf: link) == before)
    }

    @Test func binaryPlistIsAnUnsupportedFormat() throws {
        let (dir, file, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["Preset": "extended",
            "AllowedPatches": [String](), "BlockedPatches": [String]()], format: .binary, options: 0)
        try bytes.write(to: file)
        #expect(throws: PatchSelectionFileMigration.Failure.unsupportedFormat) {
            try PatchSelectionFileMigration.prepare(file: file)
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func duplicateXMLKeysCannotChooseOnePresetSilently() throws {
        let (dir, file, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("""
        <?xml version="1.0"?><plist version="1.0"><dict>
        <key>Preset</key><string>standard</string>
        <key><![CDATA[Preset]]></key><string>extended</string>
        <key>AllowedPatches</key><array/>
        <key>BlockedPatches</key><array/>
        </dict></plist>
        """.utf8)
        try bytes.write(to: file)
        #expect(throws: PatchSelectionFileMigration.Failure.invalidPlist) {
            try PatchSelectionFileMigration.prepare(file: file)
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func backupChangedBeforePublishRefusesReplacement() throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        let backup = dir.appendingPathComponent("PatchSelection.plist.before-id-migration-\(prepared.preview.sourceSHA256).bak")
        #expect(throws: PatchSelectionFileMigration.Failure.backupConflict) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256) {
                if case .beforePublish = $0 { try Data("changed backup".utf8).write(to: backup) }
            }
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path)).contains { $0.hasPrefix(".PatchSelection.plist.migrate-") })
    }

    @Test func changedStagedBytesCannotReplaceTheSelection() throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        #expect(throws: PatchSelectionFileMigration.Failure.changedSincePreview) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256) {
                if case .beforePublish = $0 {
                    let name = try #require(FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix(".PatchSelection.plist.migrate-") })
                    try Data("modified staged bytes".utf8).write(to: dir.appendingPathComponent(name))
                }
            }
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path)).contains { $0.hasPrefix(".PatchSelection.plist.migrate-") })
    }

    @Test func failureCleanupDoesNotDeleteAReplacementStagingFile() throws {
        let (dir, file, before) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = try PatchSelectionFileMigration.prepare(file: file)
        var replacement: URL?
        let unrelated = Data("replacement owned by another writer".utf8)
        #expect(throws: Injected.self) {
            try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: prepared.preview.sourceSHA256) {
                if case .beforePublish = $0 {
                    let name = try #require(FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix(".PatchSelection.plist.migrate-") })
                    let staging = dir.appendingPathComponent(name)
                    // Retain the old inode at another path so inode reuse cannot
                    // make a replacement look like the operation's own file.
                    try FileManager.default.moveItem(at: staging, to: dir.appendingPathComponent("moved-stage"))
                    try unrelated.write(to: staging)
                    replacement = staging
                    throw Injected()
                }
            }
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try Data(contentsOf: #require(replacement)) == unrelated)
    }
}

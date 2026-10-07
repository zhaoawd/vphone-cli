import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import vphone_cli

@Suite struct PatchSelectionFileMigrationTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selection-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func fixture(_ url: URL, preset: String = "extended", allowed: [String] = ["ibss.serial_label"],
                 blocked: [String] = ["kernel-exp-paravirt_user_clients"]) throws -> Data {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Preset": preset,
            "AllowedPatches": allowed, "BlockedPatches": blocked], format: .xml, options: 0)
        try data.write(to: url)
        return data
    }

    func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func parse(_ url: URL, apply: Bool = false, digest: String? = nil) throws -> any ParsableCommand {
        var args = ["fw", "selection-migrate", url.path]
        if apply { args += ["--apply"] }
        if let digest { args += ["--expected-source-sha256", digest] }
        return try VPhoneCLI.parseAsRoot(args)
    }

    @Test func previewDoesNotCreateBackupOrModifySelection() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PatchSelection.plist")
        let before = try fixture(file)
        var command = try parse(file)
        try command.run()
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["PatchSelection.plist"])
    }

    @Test func applyPreservesOriginalBytesAndExplicitDisable() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PatchSelection.plist")
        let before = try fixture(file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        var command = try parse(file, apply: true, digest: sha(before))
        try command.run()
        let data = try Data(contentsOf: file)
        let result = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(result["Preset"] as? String == "experimental")
        #expect(result["AllowedPatches"] as? [String] == ["ibss-cfw-serial_label"])
        #expect(result["BlockedPatches"] as? [String] == ["kernel-cfw-paravirt_user_clients"])
        let backup = dir.appendingPathComponent("PatchSelection.plist.before-id-migration-\(sha(before)).bak")
        #expect(try Data(contentsOf: backup) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o640)
    }

    @Test func repeatedApplyDoesNotRewriteOrCreateAnotherBackup() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PatchSelection.plist")
        let original = try fixture(file)
        var first = try parse(file, apply: true, digest: sha(original)); try first.run()
        let before = try Data(contentsOf: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        var second = try parse(file, apply: true, digest: sha(before)); try second.run()
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == names)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? UInt64
                == attributes[.systemFileNumber] as? UInt64)
    }

    @Test func staleExternalPreviewDigestRefusesBeforeBackup() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PatchSelection.plist")
        let old = try fixture(file)
        let current = try fixture(file, allowed: ["ibec.serial_label"])
        var command = try parse(file, apply: true, digest: sha(old))
        #expect(throws: (any Error).self) { try command.run() }
        #expect(try Data(contentsOf: file) == current)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["PatchSelection.plist"])
    }

    @Test func applyRequiresPreviewDigest() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PatchSelection.plist"); let before = try fixture(file)
        // Parsing can validate the apply/digest pair; retain the root registration
        // check so an absent subcommand cannot satisfy this refusal test.
        _ = try VPhoneCLI.parseAsRoot(["fw", "selection-migrate", file.path])
        #expect(throws: (any Error).self) {
            var command = try parse(file, apply: true); try command.run()
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func occupiedParentDirectoryRefusesApply() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(fd >= 0); defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0); defer { flock(fd, LOCK_UN) }
        let file = dir.appendingPathComponent("PatchSelection.plist"); let before = try fixture(file)
        var command = try parse(file, apply: true, digest: sha(before))
        #expect(throws: (any Error).self) { try command.run() }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["PatchSelection.plist"])
    }

    @Test(arguments: ["Preset", "AllowedPatches", "BlockedPatches"])
    func missingFieldsCannotAcquireDefaults(field: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PatchSelection.plist")
        var plist: [String: Any] = ["Preset": "standard", "AllowedPatches": [String](), "BlockedPatches": [String]()]
        plist.removeValue(forKey: field)
        let before = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try before.write(to: file)
        var command = try parse(file, apply: true, digest: sha(before))
        #expect(throws: (any Error).self) { try command.run() }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["PatchSelection.plist"])
    }

    @Test(arguments: ["unknown-id", "ibss.serial_label"])
    func unknownAndDuplicateIDsRefuseWithoutBackup(id: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PatchSelection.plist")
        let before = try fixture(file, allowed: ["ibss.serial_label", id])
        var command = try parse(file, apply: true, digest: sha(before))
        #expect(throws: (any Error).self) { try command.run() }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["PatchSelection.plist"])
    }

    @Test func symlinkSelectionDoesNotModifyItsTarget() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("original.plist"); let before = try fixture(target)
        let file = dir.appendingPathComponent("PatchSelection.plist")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        var command = try parse(file, apply: true, digest: sha(before))
        #expect(throws: (any Error).self) { try command.run() }
        #expect(try Data(contentsOf: target) == before)
    }

    @Test func unrelatedFieldsCannotBeDiscarded() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PatchSelection.plist")
        let before = try PropertyListSerialization.data(fromPropertyList: ["Preset": "extended",
            "AllowedPatches": [String](), "BlockedPatches": [String](), "SchemaVersion": 99], format: .xml, options: 0)
        try before.write(to: file)
        var command = try parse(file, apply: true, digest: sha(before))
        #expect(throws: (any Error).self) { try command.run() }
        #expect(try Data(contentsOf: file) == before)
    }
}

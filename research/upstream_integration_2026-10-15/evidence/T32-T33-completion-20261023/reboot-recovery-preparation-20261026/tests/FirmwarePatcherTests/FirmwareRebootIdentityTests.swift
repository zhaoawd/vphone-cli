import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import FirmwarePatcher

@Suite struct FirmwareRebootIdentityTests {
    @Test func explicitDeviceTranslationPreservesOtherStatFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.resolvingSymlinksInPath()
        let disk = canonical.appendingPathComponent("Disk.img")
        try Data("publication".utf8).write(to: disk)
        var info = stat(); #expect(lstat(disk.path, &info) == 0)
        let actual = FirmwareRebootIdentity.Disk(info)
        let old = FirmwareRebootIdentity.Disk(dev: actual.dev + 1, ino: actual.ino,
            size: actual.size, mtime_ns: actual.mtime_ns)
        let member = FirmwareRebootIdentity.Member(paths: ["Disk.img"], recorded: old, current: actual,
            sha256: String(repeating: "a", count: 64))
        let binding = try FirmwareRebootIdentity.Binding(root: canonical, members: [member])
        let result = try binding.translate(info, at: disk)
        #expect(Int64(result.st_dev) == old.dev)
        #expect(result.st_ino == info.st_ino)
        #expect(result.st_size == info.st_size)
        #expect(result.st_birthtimespec.tv_sec == info.st_birthtimespec.tv_sec)
        let outside = try binding.translate(info, at: canonical.appendingPathComponent("other.img"))
        #expect(outside.st_dev == info.st_dev)
    }

    @Test func ambiguousOrEscapingBindingsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let old = FirmwareRebootIdentity.Disk(dev: 1, ino: 2, size: 3, mtime_ns: 4)
        let current = FirmwareRebootIdentity.Disk(dev: 5, ino: 2, size: 3, mtime_ns: 4)
        let row = FirmwareRebootIdentity.Member(paths: ["Disk.img"], recorded: old, current: current,
            sha256: String(repeating: "a", count: 64))
        #expect(throws: (any Error).self) { try FirmwareRebootIdentity.Binding(root: root, members: [row, row]) }
        let escaping = FirmwareRebootIdentity.Member(paths: ["../Disk.img"], recorded: old, current: current,
            sha256: row.sha256)
        #expect(throws: (any Error).self) { try FirmwareRebootIdentity.Binding(root: root, members: [escaping]) }
    }
    @Test func newChildJournalKeepsTheNativeParentDeviceNumber() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.resolvingSymlinksInPath()
        let file = canonical.appendingPathComponent("Disk.img")
        try Data("retained first-on disk".utf8).write(to: file)
        var info = stat(); #expect(lstat(file.path, &info) == 0)
        let actual = FirmwareRebootIdentity.Disk(info)
        let old = FirmwareRebootIdentity.Disk(dev: actual.dev + 1, ino: actual.ino,
            size: actual.size, mtime_ns: actual.mtime_ns)
        let binding = try FirmwareRebootIdentity.Binding(root: canonical, members: [
            .init(paths: ["Disk.img"], recorded: old, current: actual, sha256: String(repeating: "a", count: 64))])
        try FirmwareRebootIdentity.$active.withValue(binding) {
            // A new recovery journal records actual st_dev. A legacy association
            // must remain available without replacing this native observation.
            let native = try FirmwareGuestDiskIdentity.fileInfo(file)
            #expect(Int64(native.st_dev) == actual.dev)
            let child = try FirmwareGuestDiskIdentity.fileInfo(file, expectedDevice: actual.dev)
            #expect(Int64(child.st_dev) == actual.dev)
            let historical = try FirmwareGuestDiskIdentity.fileInfo(file, expectedDevice: old.dev)
            #expect(Int64(historical.st_dev) == old.dev)
            let unknown = try FirmwareGuestDiskIdentity.fileInfo(file, expectedDevice: old.dev + 1)
            #expect(Int64(unknown.st_dev) == actual.dev)
        }
    }
    @Test func unregisteredIdentityAndUserOwnedCarrierStayRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.resolvingSymlinksInPath()
        #expect(try FirmwareRebootIdentity.load(in: canonical, generationID: String(repeating: "a", count: 64)) == nil)
        let record = canonical.appendingPathComponent(".cfw-reboot-identity.json")
        try Data("{}".utf8).write(to: record)
        #expect(throws: (any Error).self) { try FirmwareRebootIdentity.registeredBytes(record) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_REBOOT_IDENTITY_REPLAY"] != nil))
    func actualRecordedIdentityReplayUsesOnlyAnInMemoryBinding() throws {
        struct Replay: Decodable {
            let vmDirectory: String
            let generationID: String
            let identity: VPhoneFirmwareIdentity
            let members: [FirmwareRebootIdentity.Member]
        }
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_REBOOT_IDENTITY_REPLAY"])
        let replay = try JSONDecoder().decode(Replay.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let root = URL(fileURLWithPath: replay.vmDirectory)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".cfw-reboot-identity.json").path))
        #expect(try FirmwareGuestDiskIdentity.matches(replay.identity, generationID: replay.generationID, in: root) == false)
        let binding = try FirmwareRebootIdentity.Binding(root: root, members: replay.members)
        let matched = try FirmwareRebootIdentity.$active.withValue(binding) {
            try FirmwareGuestDiskIdentity.matchesRegistered(replay.identity, generationID: replay.generationID, in: root)
        }
        #expect(matched)
    }

}

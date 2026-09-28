@testable import VPhoneCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct NVRAMStorageTests {
    private enum Failure: Error { case open, create }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func createsOnlyOnceAcrossRepeatedOpens() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nvram.bin")
        let original = Data([0x12, 0x34, 0x56])
        var creates = 0
        var opens = 0
        for _ in 0..<3 {
            let data = try VPhoneNVRAMStorage.openOrCreate(at: url, openExisting: {
                opens += 1
                return try Data(contentsOf: $0)
            }, createNew: {
                creates += 1
                try original.write(to: $0, options: .withoutOverwriting)
                return original
            })
            #expect(data == original)
        }
        #expect(creates == 1)
        #expect(opens == 2)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func openFailureNeverFallsBackToCreation() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nvram.bin")
        let badData = Data("invalid storage, must not erase".utf8)
        try badData.write(to: url)
        var created = false
        #expect(throws: Failure.self) {
            let _: Int = try VPhoneNVRAMStorage.openOrCreate(at: url,
                openExisting: { _ in throw Failure.open },
                createNew: { _ in created = true; return 1 })
        }
        #expect(!created)
        #expect(try Data(contentsOf: url) == badData)
    }

    @Test(arguments: [false, true]) func rejectsBothSymlinkKinds(dangling: Bool) throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        if !dangling { try Data([7]).write(to: target) }
        let link = dir.appendingPathComponent("nvram.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var called = false
        #expect(throws: VPhoneNVRAMStorage.StorageError.notRegularFile(link.path)) {
            let _: Int = try VPhoneNVRAMStorage.openOrCreate(at: link,
                openExisting: { _ in called = true; return 1 },
                createNew: { _ in called = true; return 2 })
        }
        #expect(!called)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        if !dangling { #expect(try Data(contentsOf: target) == Data([7])) }
        else { #expect(!FileManager.default.fileExists(atPath: target.path)) }
    }

    @Test(arguments: [false, true]) func rejectsDirectoryAndFIFO(fifo: Bool) throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nvram.bin")
        if fifo { #expect(mkfifo(url.path, 0o600) == 0) }
        else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        var called = false
        #expect(throws: VPhoneNVRAMStorage.StorageError.notRegularFile(url.path)) {
            let _: Int = try VPhoneNVRAMStorage.openOrCreate(at: url,
                openExisting: { _ in called = true; return 1 },
                createNew: { _ in called = true; return 2 })
        }
        #expect(!called)
    }

    @Test func propagatesNonENOENTInspectionFailure() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let parent = dir.appendingPathComponent("not-a-directory")
        try Data([8]).write(to: parent)
        var called = false
        do {
            let _: Int = try VPhoneNVRAMStorage.openOrCreate(
                at: parent.appendingPathComponent("nvram.bin"),
                openExisting: { _ in called = true; return 1 },
                createNew: { _ in called = true; return 2 })
            Issue.record("Expected ENOTDIR")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOTDIR))
        }
        #expect(!called)
    }

    @Test func racingCreatorIsNotOverwritten() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nvram.bin")
        let rival = Data([9, 8, 7])
        #expect(throws: (any Error).self) {
            let _: Int = try VPhoneNVRAMStorage.openOrCreate(at: url,
                openExisting: { _ in Issue.record("Unexpected open"); return 1 },
                createNew: {
                    try rival.write(to: $0)
                    try Data([0]).write(to: $0, options: .withoutOverwriting)
                    return 2
                })
        }
        #expect(try Data(contentsOf: url) == rival)
    }

    @Test func propagatesCreationFailureWithoutRetry() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nvram.bin")
        var attempts = 0
        #expect(throws: Failure.self) {
            let _: Int = try VPhoneNVRAMStorage.openOrCreate(at: url,
                openExisting: { _ in Issue.record("Unexpected open"); return 1 },
                createNew: { _ in attempts += 1; throw Failure.create })
        }
        #expect(attempts == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rejectsNonFileURL() throws {
        let url = try #require(URL(string: "https://example.invalid/nvram.bin"))
        #expect(throws: VPhoneNVRAMStorage.StorageError.invalidURL) {
            let _: Int = try VPhoneNVRAMStorage.openOrCreate(at: url,
                openExisting: { _ in Issue.record("Unexpected open"); return 1 },
                createNew: { _ in Issue.record("Unexpected create"); return 2 })
        }
    }
}

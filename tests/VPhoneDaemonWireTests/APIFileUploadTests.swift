import Darwin
import Foundation
import Testing
@testable import VPhoneDaemonWire

struct APIFileUploadTests {
    @Test func identityAndSizeAreCheckedBeforeStaging() throws {
        #expect(try APIFileUploadTransaction.validateIdentity(instance: "bc862b51-525b-4e20-b6a1-a55193a615fc", hash: "hash", length: "67108864",
            expectedInstance: "BC862B51-525B-4E20-B6A1-A55193A615FC", expectedHash: "hash") == 67108864)
        for length in [nil, "-1", "1.5", "67108865", "999999999999999999999"] as [String?] {
            #expect(throws: (any Error).self) { try APIFileUploadTransaction.validateIdentity(instance: "bc862b51-525b-4e20-b6a1-a55193a615fc", hash: "hash",
                length: length, expectedInstance: "BC862B51-525B-4E20-B6A1-A55193A615FC", expectedHash: "hash") }
        }
        #expect(throws: (any Error).self) { try APIFileUploadTransaction.validateIdentity(instance: "old", hash: "hash",
            length: "1", expectedInstance: "new", expectedHash: "hash") }
    }

    @Test func commitsExactBytesAndModeWithoutFollowingDestinationSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guest-upload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try Data("unchanged".utf8).write(to: original)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
        do {
            let transaction = try APIFileUploadTransaction(destination: target.path, expectedBytes: 3, mode: 0o640)
            #expect(try transaction.reserve(3) == 0)
            #expect(write(transaction.descriptor, [UInt8(0), 255, 1], 3) == 3)
            try transaction.commit()
            #expect(throws: (any Error).self) { try transaction.commit() }
        }
        #expect(try Data(contentsOf: original) == Data("unchanged".utf8))
        #expect(try Data(contentsOf: target) == Data([0, 255, 1]))
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["original", "target"])
    }

    @Test func cancellationShortAndOverlongBodiesPreserveDestinationAndCleanStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guest-upload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("old".utf8).write(to: target)
        for scenario in ["cancelled", "short", "oversized"] {
            do {
                let transaction = try APIFileUploadTransaction(destination: target.path, expectedBytes: 3, mode: 0o600)
                if scenario == "oversized" { #expect(throws: (any Error).self) { try transaction.reserve(4) } }
                else {
                    _ = try transaction.reserve(scenario == "short" ? 2 : 3)
                    if scenario == "cancelled" { transaction.cancel() }
                }
                #expect(throws: (any Error).self) { try transaction.commit() }
            }
            #expect(try Data(contentsOf: target) == Data("old".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["target"])
        }
    }
}

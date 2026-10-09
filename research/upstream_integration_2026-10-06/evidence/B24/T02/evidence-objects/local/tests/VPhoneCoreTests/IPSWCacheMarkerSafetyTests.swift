import Darwin
import Foundation
import Testing
@testable import VPhoneCore

@Suite struct IPSWCacheMarkerSafetyTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test(arguments: [true, false])
    func predictableTemporaryPathDoesNotOverwriteAnotherFile(_ symlink: Bool) throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(".archive.vphone-complete")
        let oldTemporary = root.appendingPathComponent(destination.lastPathComponent + ".partial.\(getpid())")
        let foreign = root.appendingPathComponent("foreign")
        let sentinel = Data("preserve foreign bytes".utf8)
        try sentinel.write(to: foreign)
        if symlink { try FileManager.default.createSymbolicLink(at: oldTemporary, withDestinationURL: foreign) }
        else { try sentinel.write(to: oldTemporary) }
        try VPhoneIPSWCache.writeMarkerJSON(["format": "test"], to: destination)
        #expect(try Data(contentsOf: foreign) == sentinel)
        #expect(FileManager.default.fileExists(atPath: oldTemporary.path))
        #expect(try Data(contentsOf: oldTemporary) == sentinel)
        let marker = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        #expect(marker["format"] as? String == "test")
    }

    @Test(arguments: ["g", "?", "é"])
    func malformedDigestDoesNotMakeAnEntryUsable(_ character: String) throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = root.appendingPathComponent("archive.ipsw")
        try Data("synthetic archive bytes".utf8).write(to: entry)
        var info = stat(); try #require(lstat(entry.path, &info) == 0)
        let source = URL(string: "https://example.invalid/archive.ipsw")!
        let marker: [String: Any] = ["format": "vphone-ipsw-cache/1", "kind": "file",
            "source": ["url": source.absoluteString], "size": Int64(info.st_size),
            "sha256": String(repeating: character, count: 64),
            "file": ["inode": UInt64(info.st_ino), "mtime_ns": VPhoneIPSWCache.mtimeNanoseconds(info)]]
        try VPhoneIPSWCache.writeMarkerJSON(marker, to: VPhoneIPSWCache.markerURL(for: entry))
        #expect(VPhoneIPSWCache.entryProblem(entry, source: source) != nil)
    }

    @Test func aValidDigestAndDedicatedTemporaryArePublished() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(".entry.vphone-complete")
        try VPhoneIPSWCache.writeMarkerJSON(["sha256": String(repeating: "a", count: 64)], to: destination)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [destination.lastPathComponent])
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}

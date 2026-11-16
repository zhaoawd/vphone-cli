import Foundation
import Testing
@testable import VPhoneCoreKit

@Suite("PCC cryptexctl staging")
struct PCCCryptexctlTests {
    @Test func `OS image discovery rejects absent and escaping manifest entries`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "System.dmg")
        try Data([0x12]).write(to: image)
        for path in ["", "/System.dmg", "../System.dmg", "missing.dmg"] {
            try manifest(path).write(to: root.appending(path: "BuildManifest.plist"))
            #expect(throws: VPhonePCCCryptexctl.Error.self) { try VPhonePCCCryptexctl.osImage(in: root) }
        }
        try manifest("System.dmg").write(to: root.appending(path: "BuildManifest.plist"))
        #expect(try VPhonePCCCryptexctl.osImage(in: root) == image)
    }

    @Test func `a cached tool stages exact bytes and replaces a previous staged copy`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let restore = root.appending(path: "restore")
        for bytes in [Data([1, 2, 3]), Data([4, 5])] {
            try bytes.write(to: source)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
            try VPhonePCCCryptexctl.stage(file: source, into: restore)
            let staged = VPhonePCCCryptexctl.staged(in: restore)
            #expect(try Data(contentsOf: staged) == bytes)
            #expect(FileManager.default.isExecutableFile(atPath: staged.path))
        }
    }

    private func manifest(_ path: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "BuildIdentities": [["Manifest": ["OS": ["Info": ["Path": path]]]]],
        ], format: .xml, options: 0)
    }
}

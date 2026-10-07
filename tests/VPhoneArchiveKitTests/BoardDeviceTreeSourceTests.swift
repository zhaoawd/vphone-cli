import Foundation
import Testing
@testable import VPhoneArchiveKit

@Suite(.serialized)
struct BoardDeviceTreeSourceTests {
    func identity(_ board: String, path: String) -> [String: Any] {
        ["Info": ["DeviceClass": board], "Manifest": ["DeviceTree": ["Info": ["Path": path]]]]
    }
    func archive(_ identities: [[String: Any]]) throws -> (directory: URL, archive: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("board-source-\(UUID().uuidString)")
        let tree = directory.appendingPathComponent("input")
        let flash = tree.appendingPathComponent("Firmware/all_flash")
        try FileManager.default.createDirectory(at: flash, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: flash.appendingPathComponent("DeviceTree.d47ap.im4p"))
        try Data([4, 5]).write(to: flash.appendingPathComponent("DeviceTree.j717ap.im4p"))
        let manifest: [String: Any] = ["ProductVersion": "26.1", "ProductBuildVersion": "23B85",
                                     "SupportedProductTypes": ["iPhone17,3", "iPad16,3"], "BuildIdentities": identities]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: tree.appendingPathComponent("BuildManifest.plist"))
        let archive = directory.appendingPathComponent("input.ipsw")
        try VPhoneArchiveWriter.create(archive: archive, from: tree)
        return (directory, archive)
    }
    @Test func multiBoardSourceUsesRequestedProductBuildAndBoardWithoutExtractingTree() throws {
        let fixture = try archive([identity("j717ap", path: "Firmware/all_flash/DeviceTree.j717ap.im4p"),
                                   identity("D47AP", path: "Firmware/all_flash/DeviceTree.d47ap.im4p")])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try VPhoneBoardDeviceTreeSource.read(from: fixture.archive, productType: "iPhone17,3", deviceClass: "d47ap", version: "26.1", build: "23B85")
        #expect(source.contents == Data([1, 2, 3]))
        #expect(source.member == "Firmware/all_flash/DeviceTree.d47ap.im4p")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == ["input", "input.ipsw"])
        for (product, version, build) in [("iPhone18,1", "26.1", "23B85"), ("iPhone17,3", "26.2", "23B85"), ("iPhone17,3", "26.1", "wrong")] {
            #expect(throws: (any Error).self) { try VPhoneBoardDeviceTreeSource.read(from: fixture.archive, productType: product, deviceClass: "d47ap", version: version, build: build) }
        }
    }
    @Test func duplicateIdenticalMemberIsAllowedButConflictingMembersAreRejected() throws {
        for paths in [["Firmware/all_flash/DeviceTree.d47ap.im4p", "Firmware/all_flash/DeviceTree.d47ap.im4p"],
                      ["Firmware/all_flash/DeviceTree.d47ap.im4p", "Other/DeviceTree.d47ap.im4p"]] {
            let fixture = try archive(paths.map { identity("d47ap", path: $0) })
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if Set(paths).count == 1 {
                #expect(try VPhoneBoardDeviceTreeSource.read(from: fixture.archive, productType: "iPhone17,3", deviceClass: "d47ap", version: "26.1", build: "23B85").contents == Data([1, 2, 3]))
            } else {
                #expect(throws: (any Error).self) { try VPhoneBoardDeviceTreeSource.read(from: fixture.archive, productType: "iPhone17,3", deviceClass: "d47ap", version: "26.1", build: "23B85") }
            }
        }
    }
    @Test func unsafeMemberWrongBoardAndMissingTreeAreRejected() throws {
        for path in ["../DeviceTree.d47ap.im4p", "/DeviceTree.d47ap.im4p", "Firmware//DeviceTree.d47ap.im4p", "Firmware/all_flash/DeviceTree.j717ap.im4p", "Missing/DeviceTree.d47ap.im4p"] {
            let fixture = try archive([identity("d47ap", path: path)])
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            #expect(throws: (any Error).self) { try VPhoneBoardDeviceTreeSource.read(from: fixture.archive, productType: "iPhone17,3", deviceClass: "d47ap", version: "26.1", build: "23B85") }
        }
    }
}

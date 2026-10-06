import CryptoKit
import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareVersionInputsTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func write(_ values: [String: Any], name: String = "iPhone-BuildManifest.plist") throws {
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
                .write(to: root.appendingPathComponent(name))
        }
    }

    @Test func versionAndDigestComeFromTheSameManifestBytes() throws {
        let fixture = try Fixture()
        try fixture.write(["ProductVersion": "26.1", "ProductBuildVersion": "23B85"])
        let inputs = try FirmwareVersionInputs.read(in: fixture.root)
        #expect(inputs.baseVersion == "26.1")
        #expect(inputs.cloudOSVersion == nil)
        let data = try Data(contentsOf: fixture.root.appendingPathComponent("iPhone-BuildManifest.plist"))
        #expect(inputs.manifests.first { $0.name == "iPhone-BuildManifest.plist" }?.sha256 ==
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        try inputs.validate(in: fixture.root)
    }

    @Test func changedBuildIsRejectedEvenWhenProductVersionIsUnchanged() throws {
        let fixture = try Fixture()
        try fixture.write(["ProductVersion": "26.1", "ProductBuildVersion": "23B85"])
        let inputs = try FirmwareVersionInputs.read(in: fixture.root)
        try fixture.write(["ProductVersion": "26.1", "ProductBuildVersion": "other"])
        #expect(throws: (any Error).self) { try inputs.validate(in: fixture.root) }
    }

    @Test func previouslyMissingManifestCannotAppearAfterFreezing() throws {
        let fixture = try Fixture()
        let inputs = try FirmwareVersionInputs.read(in: fixture.root)
        try fixture.write(["ProductVersion": "26.1"])
        #expect(throws: (any Error).self) { try inputs.validate(in: fixture.root) }
    }

    @Test func presentManifestCannotDisappearAfterFreezing() throws {
        let fixture = try Fixture()
        try fixture.write(["ProductVersion": "26.1"])
        let inputs = try FirmwareVersionInputs.read(in: fixture.root)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("iPhone-BuildManifest.plist"))
        #expect(throws: (any Error).self) { try inputs.validate(in: fixture.root) }
    }

    @Test(arguments: [Data("invalid plist".utf8), Data("<plist><array/></plist>".utf8)])
    func corruptManifestIsRejected(_ data: Data) throws {
        let fixture = try Fixture()
        try data.write(to: fixture.root.appendingPathComponent("iPhone-BuildManifest.plist"))
        #expect(throws: (any Error).self) { _ = try FirmwareVersionInputs.read(in: fixture.root) }
    }

    @Test func unreadableManifestIsNotClassifiedAsMissing() throws {
        let fixture = try Fixture()
        try fixture.write(["ProductVersion": "26.1"])
        let file = fixture.root.appendingPathComponent("iPhone-BuildManifest.plist")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(throws: (any Error).self) { _ = try FirmwareVersionInputs.read(in: fixture.root) }
    }
    @Test(arguments: ["", "unknown", "27.foo", "26..4", "+26.4", "26.4-beta"])
    func unrecognizedProductVersionIsRejected(_ value: String) throws {
        let fixture = try Fixture()
        try fixture.write(["ProductVersion": value])
        #expect(throws: (any Error).self) { _ = try FirmwareVersionInputs.read(in: fixture.root) }
    }

    @Test func productVersionHasToBeAString() throws {
        let fixture = try Fixture()
        try fixture.write(["ProductVersion": 26])
        #expect(throws: (any Error).self) { _ = try FirmwareVersionInputs.read(in: fixture.root) }
    }

    @Test(arguments: ["garbage.26.4", "26..4", "26.4.beta", "+26.4", "26.4-beta"])
    func versionFloorDoesNotDropMalformedComponents(_ value: String) {
        #expect(!FirmwarePipeline.productVersionAtLeast(value, 26, 4))
    }

    @Test func manifestSymlinkIsRejected() throws {
        let fixture = try Fixture()
        try fixture.write(["ProductVersion": "26.1"], name: "original.plist")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("iPhone-BuildManifest.plist").path,
            withDestinationPath: fixture.root.appendingPathComponent("original.plist").path)
        #expect(throws: (any Error).self) { _ = try FirmwareVersionInputs.read(in: fixture.root) }
    }

    @Test func manifestDirectoryIsRejected() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("iPhone-BuildManifest.plist"),
            withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { _ = try FirmwareVersionInputs.read(in: fixture.root) }
    }

    @Test(arguments: ["26.4", "26.4.1", "27", "26.3", "25.9"])
    func completeNumericVersionFloorIsPreserved(_ version: String) {
        #expect(FirmwarePipeline.productVersionAtLeast(version, 26, 4) ==
            ["26.4", "26.4.1", "27"].contains(version))
    }

}

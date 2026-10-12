import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareInstalledReadbackTests {
    @Test(arguments: ["success", "wrong-image", "writable", "wrong-root", "changed-image", "root-replaced", "inspect-root-replaced", "linked-subtree", "detach"])
    func installedDiskRequiresLiveReadonlyAssociation(_ fault: String) throws {
        let fixture = try FirmwareComponentReceiptTests.Fixture()
        let transaction = try FirmwareReceiptPublicationTests().begin(fixture)
        let image = fixture.generationFixture.disk
        let root = transaction.work.appendingPathComponent("mounted")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("installed payload".utf8).write(to: root.appendingPathComponent("kernelcache"))
        let attachment = FirmwareInstalledReadback.Attachment(image: image, device: "/dev/disk999",
            volumes: ["preboot": .init(device: "disk998s5", root: root)])
        var detachCount = 0
        var inspections = 0
        if fault == "linked-subtree" {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("unknown"), withDestinationURL: transaction.work)
        }
        let operations = FirmwareInstalledReadback.Operations(attach: { _, _ in attachment },
            inspect: { _ in
                inspections += 1
                if fault == "inspect-root-replaced", inspections == 2 {
                    try FileManager.default.moveItem(at: root, to: transaction.work.appendingPathComponent("old-mount"))
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                }
                func plist(_ value: Any) throws -> Data {
                    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
                }
                let mount = fault == "wrong-root" ? "/different" : root.path
                return try .init(images: plist(["images": [["image-path": fault == "wrong-image" ? "/other.img" : image.path,
                    "system-entities": [["dev-entry": "/dev/disk999"]]]]]),
                    containers: plist(["Containers": [["ContainerReference": "disk998", "PhysicalStores": [["DeviceIdentifier": "disk999s1"]],
                        "Volumes": [["DeviceIdentifier": "disk998s5", "MountPoint": mount]]]]]),
                    volumes: ["preboot": plist(["DeviceIdentifier": "disk998s5", "MountPoint": mount, "ReadOnlyVolume": fault != "writable"])])
            }, detach: { _ in detachCount += 1; if fault == "detach" { throw POSIXError(.EIO) } })
        let reader = try FirmwareInstalledReadback(transaction: transaction)
        var escaped: FirmwareInstalledReadback.Volumes?
        func perform() throws {
            try reader.withReadOnlyVolumes(operations: operations) { volumes in
                escaped = volumes
                #expect(try volumes.readUniqueComponent("kernelcache") == Data("installed payload".utf8))
                #expect(try volumes.read(volume: "preboot", path: "kernelcache") == Data("installed payload".utf8))
                if fault == "changed-image" { try Data("changed".utf8).write(to: image) }
                if fault == "root-replaced" {
                    try FileManager.default.moveItem(at: root, to: transaction.work.appendingPathComponent("old-mount"))
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                    try Data("installed payload".utf8).write(to: root.appendingPathComponent("kernelcache"))
                }
            }
        }
        if fault == "success" { try perform() } else { #expect(throws: (any Error).self) { try perform() } }
        #expect(detachCount == 1)
        if let escaped { #expect(throws: (any Error).self) { try escaped.read(volume: "preboot", path: "kernelcache") } }
    }
}

extension FirmwareInstalledReadbackTests {
    static func operations(image: URL, root: URL) -> FirmwareInstalledReadback.Operations {
        let attachment = FirmwareInstalledReadback.Attachment(image: image, device: "/dev/disk999", volumes: ["preboot": .init(device: "disk998s5", root: root)])
        return .init(attach: { _, _ in attachment }, inspect: { _ in
            func plist(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
            return try .init(images: plist(["images": [["image-path": image.path, "system-entities": [["dev-entry": "/dev/disk999"]]]]]),
                containers: plist(["Containers": [["ContainerReference": "disk998", "PhysicalStores": [["DeviceIdentifier": "disk999s1"]],
                    "Volumes": [["DeviceIdentifier": "disk998s5", "MountPoint": root.path]]]]]),
                volumes: ["preboot": plist(["DeviceIdentifier": "disk998s5", "MountPoint": root.path, "ReadOnlyVolume": true])])
        }, detach: { _ in })
    }
}

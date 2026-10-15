import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareInstalledVolumeAssociationTests {
    @Test(arguments: ["/tmp", "/var"])
    func hostAliasNormalizationIsLimited(_ alias: String) throws {
        #expect(FirmwareInstalledReadback.sameHostPath("/private" + alias + "/mount", alias + "/mount"))
        #expect(FirmwareInstalledReadback.sameHostPath(alias + "/mount", "/private" + alias + "/mount"))
        #expect(!FirmwareInstalledReadback.sameHostPath(alias + "/alias", alias + "/mount"))
        #expect(!FirmwareInstalledReadback.sameHostPath(alias + "/../" + alias.dropFirst() + "/mount", alias + "/mount"))
        #expect(!FirmwareInstalledReadback.sameHostPath(alias + "-other/mount", alias + "/mount"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(!FirmwareInstalledReadback.sameHostPath(link.path, root.path))
    }

    @Test(arguments: ["missing-list-mount", "matching-list-mount", "wrong-list-mount", "wrong-info-mount", "wrong-info-device", "writable", "missing-info-mount", "uuid", "duplicate", "missing-volume"])
    func apfsMembershipAndInfoMountAreBothRequired(_ fault: String) throws {
        let image = URL(fileURLWithPath: "/fixture/Disk.img")
        let root = URL(fileURLWithPath: "/fixture/preboot", isDirectory: true)
        let attachment = FirmwareInstalledReadback.Attachment(image: image, device: "/dev/disk999",
            volumes: ["preboot": .init(device: "disk998s5", root: root)])
        func plist(_ object: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) }
        var member: [String: Any] = ["DeviceIdentifier": "disk998s5", "APFSVolumeUUID": "AABBCCDD-0000-0000-0000-000000000001"]
        if fault == "matching-list-mount" { member["MountPoint"] = root.path }
        if fault == "wrong-list-mount" { member["MountPoint"] = "/different" }
        let members = fault == "duplicate" ? [member, member] : fault == "missing-volume" ? [] : [member]
        let observation = try FirmwareInstalledReadback.Observation(
            images: plist(["images": [["image-path": image.path, "system-entities": [["dev-entry": "/dev/disk999"]]]]]),
            containers: plist(["Containers": [["ContainerReference": "disk998", "PhysicalStores": [["DeviceIdentifier": "disk999s1"]], "Volumes": members]]]),
            volumes: ["preboot": plist(["DeviceIdentifier": fault == "wrong-info-device" ? "disk998s6" : "disk998s5", "MountPoint": fault == "wrong-info-mount" ? "/different" : fault == "missing-info-mount" ? "" : root.path,
                "VolumeUUID": fault == "uuid" ? "AABBCCDD-0000-0000-0000-000000000002" : "AABBCCDD-0000-0000-0000-000000000001", "WritableVolume": fault == "writable"])])
        if ["missing-list-mount", "matching-list-mount"].contains(fault) { try FirmwareInstalledReadback.validate(attachment, observation: observation) }
        else { #expect(throws: (any Error).self) { try FirmwareInstalledReadback.validate(attachment, observation: observation) } }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_VOLUME_OBSERVATION"] != nil))
    func actualAPFSObservationMatchesExactMountedVolumes() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VPHONE_VOLUME_OBSERVATION"]))
        struct Saved: Decodable {
            struct Volume: Decodable { let device: String; let root: String }
            let image: String; let device: String; let volumes: [String: Volume]
        }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: root.appendingPathComponent("attachment.json")))
        let attachment = FirmwareInstalledReadback.Attachment(image: URL(fileURLWithPath: saved.image), device: saved.device,
            volumes: saved.volumes.mapValues { .init(device: $0.device, root: URL(fileURLWithPath: $0.root)) })
        let observation = try FirmwareInstalledReadback.Observation(
            images: Data(contentsOf: root.appendingPathComponent("images.plist")),
            containers: Data(contentsOf: root.appendingPathComponent("containers.plist")),
            volumes: saved.volumes.mapValues { _ in Data() })
        var infos: [String: Data] = [:]
        for name in saved.volumes.keys { infos[name] = try Data(contentsOf: root.appendingPathComponent(name + ".plist")) }
        try FirmwareInstalledReadback.validate(attachment,
            observation: .init(images: observation.images, containers: observation.containers, volumes: infos),
            writablePreboot: ProcessInfo.processInfo.environment["VPHONE_VOLUME_WRITABLE_PREBOOT"] == "1")
    }
}

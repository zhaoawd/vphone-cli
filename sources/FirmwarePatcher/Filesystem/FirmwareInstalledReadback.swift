import Foundation
import Darwin
import VPhoneCore

/// Read-only final installed-image proof. It cannot authorize an image write or
/// infer the currently booted snapshot. Only the configured VM disk is admitted.
struct FirmwareInstalledReadback {
    struct Volume { let device: String; let root: URL }
    struct Attachment { let image: URL; let device: String; let volumes: [String: Volume] }
    struct Observation { let images: Data; let containers: Data; let volumes: [String: Data] }
    struct Operations {
        let attach: (URL, URL) throws -> Attachment
        let inspect: (Attachment) throws -> Observation
        let detach: (Attachment) throws -> Void
    }
    final class Volumes {
        fileprivate var active = true
        fileprivate let roots: [String: Volume]
        fileprivate init(_ roots: [String: Volume]) { self.roots = roots }
        func withPaths<T>(_ body: ([String: URL]) throws -> T) throws -> T {
            guard active else { throw FirmwareGeneration.fail("Installed reader callback expired") }
            return try body(roots.mapValues(\.root))
        }
        func readUniqueComponent(_ component: String) throws -> Data {
            guard active, let root = roots["preboot"]?.root else { throw FirmwareGeneration.fail("Installed Preboot reader expired") }
            let names: Set<String>
            switch component.lowercased() {
            case "kernelcache": names = ["kernelcache", "kernelcache.research.vphone600"]
            case "devicetree": names = ["devicetree", "devicetree.img4", "devicetree.vphone600ap.im4p"]
            default: throw FirmwareGeneration.fail("No supported installed Preboot target for this component")
            }
            var paths: [String] = []
            func visit(_ directory: URL) throws {
                // Throw on unreadable subtrees or links: skipping one could
                // hide a second matching target and falsely establish uniqueness.
                for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                    let file = directory.appendingPathComponent(name)
                    var info = stat()
                    guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
                        throw FirmwareGeneration.fail("Uncertain or linked installed Preboot subtree")
                    }
                    if names.contains(name.lowercased()) { paths.append(try FirmwareComponentReceipt.relative(file, in: root)) }
                    if info.st_mode & S_IFMT == S_IFDIR { try visit(file) }
                }
            }
            try visit(root)
            guard paths.count == 1 else { throw FirmwareGeneration.fail("Installed Preboot component is missing or ambiguous") }
            return try read(volume: "preboot", path: paths[0])
        }
        func read(volume: String, path: String) throws -> Data {
            guard active, let root = roots[volume]?.root else { throw FirmwareGeneration.fail("Installed reader callback expired or volume unknown") }
            let file = root.appendingPathComponent(path)
            guard try FirmwareComponentReceipt.relative(file, in: root) == path else { throw FirmwareGeneration.fail("Installed target escapes its volume") }
            var data = Data()
            try FirmwareGeneration.readFile(file) { data.append($0) }
            return data
        }
    }
    let transaction: FirmwareTransaction
    let image: URL
    let imageSHA256: String
    private static let slices = ["system": "s1", "hardware": "s3", "preboot": "s5"]

    init(transaction: FirmwareTransaction) throws {
        self.transaction = transaction
        let config = try VPhoneCreateDigest.strictFileData(transaction.vmDirectory.appendingPathComponent("config.plist"), maximumBytes: 1 << 20)
        let manifest = try Self.dictionary(config)
        guard manifest["diskImage"] as? String == "Disk.img" else { throw FirmwareGeneration.fail("Installed reader requires the exact configured Disk.img") }
        image = transaction.vmDirectory.appendingPathComponent("Disk.img")
        imageSHA256 = try FirmwareGeneration.fileSHA256(image)
        try qualify()
    }

    func withReadOnlyVolumes<T>(body: (Volumes) throws -> T) throws -> T {
        try withReadOnlyVolumes(operations: Self.liveOperations(transaction: transaction), body: body)
    }

    func withReadOnlyVolumes<T>(operations: Operations, body: (Volumes) throws -> T) throws -> T {
        try qualify()
        let attachment = try operations.attach(image, transaction.work)
        var detached = false
        do {
            guard attachment.image == image, !attachment.volumes.isEmpty else { throw FirmwareGeneration.fail("Installed image attachment differs") }
            for volume in attachment.volumes.values {
                _ = try FirmwareComponentReceipt.relative(volume.root, in: transaction.work)
                try FirmwareGeneration.ensureDirectory(volume.root, create: false)
            }
            try Self.validate(attachment, observation: operations.inspect(attachment))
            let identities = try attachment.volumes.mapValues { try Self.identity($0.root) }
            let volumes = Volumes(attachment.volumes)
            defer { volumes.active = false }
            let value = try body(volumes)
            guard try attachment.volumes.mapValues({ try Self.identity($0.root) }) == identities else {
                throw FirmwareGeneration.fail("Installed volume identity changed during readback")
            }
            try Self.validate(attachment, observation: operations.inspect(attachment))
            guard try attachment.volumes.mapValues({ try Self.identity($0.root) }) == identities else {
                throw FirmwareGeneration.fail("Installed volume identity changed during final observation")
            }
            try qualify()
            detached = true
            try operations.detach(attachment)
            try qualify()
            return value
        } catch {
            if !detached { try operations.detach(attachment) }
            throw error
        }
    }

    private static func identity(_ root: URL) throws -> String {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw FirmwareGeneration.fail("Installed volume root is missing or linked") }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private func qualify() throws {
        let journal = transaction.journalSnapshot
        guard let binding = journal.planBinding,
              try FirmwareComponentReceipt.relative(image, in: transaction.vmDirectory) == "Disk.img",
              try FirmwareGeneration.fileSHA256(image) == imageSHA256 else {
            throw FirmwareGeneration.fail("Installed image changed during proof")
        }
        try binding.validate(journal: journal, directory: transaction.vmDirectory, currentCatalog: true)
    }

    static func validate(_ attachment: Attachment, observation: Observation, writablePreboot: Bool = false) throws {
        let images = try dictionary(observation.images)["images"] as? [[String: Any]] ?? []
        let matches = images.filter { sameHostPath($0["image-path"] as? String, attachment.image.path) }
        guard matches.count == 1, let entries = matches[0]["system-entities"] as? [[String: Any]],
              attachment.device.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil,
              entries.filter({ ($0["dev-entry"] as? String) == attachment.device }).count == 1 else {
            throw FirmwareGeneration.fail("Installed disk has no unique image/device association")
        }
        let physical = String(attachment.device.dropFirst(5)) + "s1"
        let containers = try dictionary(observation.containers)["Containers"] as? [[String: Any]] ?? []
        let matching = containers.filter {
            ($0["PhysicalStores"] as? [[String: Any]])?.compactMap { $0["DeviceIdentifier"] as? String } == [physical]
        }
        guard matching.count == 1, let reference = matching[0]["ContainerReference"] as? String,
              reference.range(of: "^disk[0-9]+$", options: .regularExpression) != nil,
              let volumes = matching[0]["Volumes"] as? [[String: Any]] else {
            throw FirmwareGeneration.fail("Installed APFS physical-store association differs")
        }
        for (name, volume) in attachment.volumes {
            let members = volumes.filter { ($0["DeviceIdentifier"] as? String) == volume.device }
            guard let slice = slices[name], volume.device == reference + slice,
                  members.count == 1, let raw = observation.volumes[name] else {
                throw FirmwareGeneration.fail("Installed volume association differs")
            }
            // `diskutil apfs list -plist` establishes container membership but
            // does not always include MountPoint. The per-device `info -plist`
            // observation below must always establish the exact mount path.
            if let mount = members[0]["MountPoint"] {
                guard sameHostPath(mount as? String, volume.root.path) else {
                    throw FirmwareGeneration.fail("Installed APFS mount observation differs")
                }
            }
            let info = try dictionary(raw)
            if members[0]["APFSVolumeUUID"] != nil || info["VolumeUUID"] != nil {
                guard let memberUUID = members[0]["APFSVolumeUUID"] as? String,
                      let infoUUID = info["VolumeUUID"] as? String,
                      let expected = UUID(uuidString: memberUUID),
                      let observed = UUID(uuidString: infoUUID), expected == observed else {
                    throw FirmwareGeneration.fail("Installed APFS volume UUID differs")
                }
            }
            guard (info["DeviceIdentifier"] as? String) == volume.device,
                  sameHostPath(info["MountPoint"] as? String, volume.root.path),
                  try Self.volumeReadOnly(info) == !(writablePreboot && name == "preboot") else {
                throw FirmwareGeneration.fail("Installed volume is not the exact readonly mount")
            }
        }
    }

    /// Foundation can retain /tmp and /var while diskutil reports their
    /// /private paths. Normalize only those macOS system aliases; do not resolve
    /// arbitrary symlinks or dot components supplied by an observation.
    static func sameHostPath(_ observed: String?, _ expected: String) -> Bool {
        guard let observed else { return false }
        func normalize(_ path: String) -> String {
            for alias in ["/tmp", "/var"] where path == alias || path.hasPrefix(alias + "/") {
                return "/private" + path
            }
            return path
        }
        return normalize(observed) == normalize(expected)
    }

    static func volumeReadOnly(_ info: [String: Any]) throws -> Bool {
        let readonly = info["ReadOnlyVolume"] as? Bool
        let writable = info["WritableVolume"] as? Bool
        guard readonly != nil || writable != nil,
              info["ReadOnlyVolume"] == nil || readonly != nil,
              info["WritableVolume"] == nil || writable != nil else {
            throw FirmwareGeneration.fail("Installed volume write state is unknown")
        }
        if let readonly, let writable {
            guard readonly != writable else { throw FirmwareGeneration.fail("Installed volume write state contradicts itself") }
        }
        return readonly ?? !writable!
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw FirmwareGeneration.fail("Invalid installed disk observation")
        }
        return value
    }

    static func liveOperations(transaction: FirmwareTransaction, writablePreboot: Bool = false) -> Operations {
        let run: (String, [String]) throws -> Data = { try transaction.runTool($0, $1) }
        return Operations(attach: { image, work in
            let raw = try run("/usr/bin/hdiutil", ["attach"] + (writablePreboot ? [] : ["-readonly"]) + ["-nomount", "-nobrowse", "-plist", image.path])
            let entities = try Self.dictionary(raw)["system-entities"] as? [[String: Any]] ?? []
            let device = try FirmwareTransaction.detachDevice(entries: entities, inspect: { device in
                try Self.dictionary(run("/usr/sbin/diskutil", ["info", "-plist", device]))
            })
            do {
                let listing = try Self.dictionary(run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]))
                let physical = String(device.dropFirst(5)) + "s1"
                let containers = (listing["Containers"] as? [[String: Any]] ?? []).filter {
                    ($0["PhysicalStores"] as? [[String: Any]])?.compactMap { $0["DeviceIdentifier"] as? String } == [physical]
                }
                guard containers.count == 1, let reference = containers[0]["ContainerReference"] as? String,
                      reference.range(of: "^disk[0-9]+$", options: .regularExpression) != nil,
                      let volumes = containers[0]["Volumes"] as? [[String: Any]] else { throw FirmwareGeneration.fail("New installed attachment has no unique APFS container") }
                let mount = work.appendingPathComponent("installed-readback-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                var roots: [String: Volume] = [:]
                for (name, slice) in Self.slices.sorted(by: { $0.key < $1.key }) {
                    let volume = reference + slice
                    guard volumes.filter({ ($0["DeviceIdentifier"] as? String) == volume }).count == 1 else { throw FirmwareGeneration.fail("Installed APFS volume missing") }
                    let root = mount.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    _ = try run("/sbin/mount_apfs", ["-o", writablePreboot && name == "preboot" ? "rw" : "rdonly", "/dev/" + volume, root.path])
                    roots[name] = Volume(device: volume, root: root)
                }
                return Attachment(image: image, device: device, volumes: roots)
            } catch {
                _ = try run("/usr/bin/hdiutil", ["detach", device])
                throw error
            }
        }, inspect: { attachment in
            var volumes: [String: Data] = [:]
            for (name, volume) in attachment.volumes {
                volumes[name] = try run("/usr/sbin/diskutil", ["info", "-plist", "/dev/" + volume.device])
            }
            return try Observation(images: run("/usr/bin/hdiutil", ["info", "-plist"]),
                containers: run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]), volumes: volumes)
        }, detach: { attachment in _ = try run("/usr/bin/hdiutil", ["detach", attachment.device]) })
    }
}

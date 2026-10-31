import Darwin
import Foundation
import VPhoneCore

/// An explicit root registration associates named historical files after a
/// device-number change. It grants no effect, source, or publication authority.
enum FirmwareRebootIdentity {
    @TaskLocal static var active: Binding?
    struct Disk: Codable, Equatable, Sendable {
        let dev: Int64
        let ino: UInt64
        let size: Int64
        let mtime_ns: Int64
        init(dev: Int64, ino: UInt64, size: Int64, mtime_ns: Int64) {
            self.dev = dev; self.ino = ino; self.size = size; self.mtime_ns = mtime_ns
        }
        init(_ info: stat) {
            self.init(dev: Int64(info.st_dev), ino: UInt64(info.st_ino), size: Int64(info.st_size),
                mtime_ns: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
        }
    }
    struct Member: Codable, Sendable {
        let paths: [String]
        let recorded: Disk
        let current: Disk
        let sha256: String
    }
    struct Registration: Decodable {
        let schemaVersion: Int
        let kind: String
        let vmDirectory: String
        let generationID: String
        let approvedPlanSHA256: String
        let volumeUUID: String
        let members: [Member]
    }
    struct Binding: Sendable {
        let root: URL
        let members: [Member]
        init(root: URL, members: [Member]) throws {
            guard root.standardizedFileURL.resolvingSymlinksInPath() == root, !members.isEmpty else {
                throw FirmwareGeneration.fail("Exact recovery namespace and explicit files required")
            }
            var identities: Set<String> = []; var paths: Set<String> = []
            for member in members {
                let old = member.recorded; let current = member.current
                guard old.dev >= 0, current.dev >= 0, old.size >= 0, current.size >= 0, old.mtime_ns >= 0,
                      old.dev != current.dev, old.ino == current.ino, old.size == current.size,
                      old.mtime_ns == current.mtime_ns, Int32(exactly: old.dev) != nil,
                      identities.insert("\(current.dev):\(current.ino)").inserted,
                      FirmwareGeneration.validDigest(member.sha256), !member.paths.isEmpty else {
                    throw FirmwareGeneration.fail("Recovery may associate only a recorded device-number change")
                }
                for path in member.paths {
                    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                    guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                          paths.insert(path).inserted else {
                        throw FirmwareGeneration.fail("Ambiguous or escaping recovery path")
                    }
                }
            }
            self.root = root; self.members = members
        }
        func translate(_ info: stat, at file: URL) throws -> stat {
            let prefix = root.path + "/"
            guard file.path.hasPrefix(prefix), file.standardizedFileURL == file,
                  let member = members.first(where: { $0.paths.contains(String(file.path.dropFirst(prefix.count))) }) else {
                return info
            }
            guard file.resolvingSymlinksInPath() == file else {
                throw FirmwareGeneration.fail("Linked recovered file")
            }
            var current = stat()
            guard lstat(file.path, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
                  current.st_nlink == 1, Disk(current) == Disk(info) else {
                throw FirmwareGeneration.fail("Registered recovered file metadata differs")
            }
            guard Disk(current) == member.current else { return info }
            var result = info
            result.st_dev = dev_t(member.recorded.dev)
            return result
        }
    }

    static func load(in root: URL, generationID: String) throws -> Binding? {
        let file = root.appendingPathComponent(".cfw-reboot-identity.json")
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw FirmwareGeneration.fail("Cannot read recovery registration")
        }
        let data = try registeredBytes(file)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard Set(object?.keys.map { $0 } ?? []) == Set(["schemaVersion", "kind", "vmDirectory", "generationID",
            "approvedPlanSHA256", "volumeUUID", "members"]) else {
            throw FirmwareGeneration.fail("Unknown recovery registration fields")
        }
        guard let rows = object?["members"] as? [[String: Any]], rows.allSatisfy({ row in
            Set(row.keys) == Set(["paths", "recorded", "current", "sha256"]) &&
            ["recorded", "current"].allSatisfy { key in
                guard let fields = row[key] as? [String: Any] else { return false }
                return Set(fields.keys) == Set(["dev", "ino", "size", "mtime_ns"])
            }
        }) else { throw FirmwareGeneration.fail("Unknown recovered identity fields") }
        let record = try JSONDecoder().decode(Registration.self, from: data)
        let values = try root.resourceValues(forKeys: [.volumeUUIDStringKey])
        guard record.schemaVersion == 1, record.kind == "explicit-reboot-requalification",
              record.vmDirectory == root.path, record.generationID == generationID,
              FirmwareGeneration.validDigest(generationID), FirmwareGeneration.validDigest(record.approvedPlanSHA256),
              let expected = UUID(uuidString: record.volumeUUID),
              let actualString = values.volumeUUIDString, let actual = UUID(uuidString: actualString), expected == actual else {
            throw FirmwareGeneration.fail("Recovery registration differs from this VM, generation or volume")
        }
        let binding = try Binding(root: root, members: record.members)
        for member in record.members {
            var found: [URL] = []
            for name in member.paths {
                let path = root.appendingPathComponent(name)
                var current = stat()
                if lstat(path.path, &current) != 0 {
                    if errno == ENOENT { continue }
                    throw FirmwareGeneration.fail("Cannot inspect registered recovery path")
                }
                guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                      path.resolvingSymlinksInPath() == path else {
                    throw FirmwareGeneration.fail("Linked or shared registered recovery path")
                }
                if Disk(current) == member.current { found.append(path) }
            }
            guard found.count == 1, let path = found.first else {
                throw FirmwareGeneration.fail("Recovered inode has no unique recorded path")
            }
            var current = stat()
            guard lstat(path.path, &current) == 0 else { throw FirmwareGeneration.fail("Missing recovered inode") }
            _ = try binding.translate(current, at: path)
        }
        return binding
    }

    static func registeredBytes(_ file: URL) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FirmwareGeneration.fail("Cannot open recovery registration") }
        defer { close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_uid == 0, before.st_mode & 0o7777 == 0o444,
              before.st_size >= 0, before.st_size <= 1 << 20 else {
            throw FirmwareGeneration.fail("Recovery registration must be an immutable root-owned file")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: Int(before.st_size) + 1) ?? Data()
        guard data.count == before.st_size, fstat(fd, &after) == 0, lstat(file.path, &named) == 0,
              [after, named].allSatisfy({ value in
                  value.st_dev == before.st_dev && value.st_ino == before.st_ino &&
                  value.st_size == before.st_size && value.st_uid == before.st_uid &&
                  value.st_mode == before.st_mode && value.st_nlink == before.st_nlink &&
                  value.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec &&
                  value.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec &&
                  value.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec &&
                  value.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
              }) else { throw FirmwareGeneration.fail("Recovery registration changed during read") }
        return data
    }

}

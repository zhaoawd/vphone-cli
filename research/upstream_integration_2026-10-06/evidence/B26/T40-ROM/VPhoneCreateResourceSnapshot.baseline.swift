import CryptoKit
import Darwin
import Foundation

/// Private copies of the resource inputs covered by one create attempt.
/// This deliberately does not claim a closed Python or external-tool runtime.
public final class VPhoneCreateResourceSnapshot {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let kind: String
        public let mode: UInt16
        public let bytes: Int64
        public let sha256: String?
    }

    public struct Manifest: Codable, Sendable {
        public let schemaVersion: Int
        public let snapshotId: String
        public let sourceResourceBase: String
        public let sourceExecutable: String
        public let snapshotPath: String
        public let sha256: String
        public let bytes: Int64
        public let entries: [Entry]
        public let closureLimits: [String]
        public let retention: String
    }

    public let directory: URL
    public let resources: VPhoneResources
    public let executable: URL
    public let manifest: Manifest
    private var retained = false

    public static let closureLimits = [
        "Python interpreter, Python framework, third-party packages and their native dependencies are external",
        "PATH tools, host SDK/compiler, Virtualization framework ROMs and JB compilation are external",
        "Existing VM cfw_input/cfw_jb_input, firmware sources and mutable caches are external",
        "In-process code is loaded by the invoking executable; a new attempt may use another accepted build",
        "A resource snapshot is not a verified Core Bundle receipt and does not publish a VM binding",
        "File ownership, ACLs, extended attributes and source touch history are not frozen",
    ]
    private static let maximumBytes: Int64 = 2 << 30
    private static let maximumSnapshots = 8

    private struct Input {
        let source: URL
        let entry: Entry
        let info: stat
    }

    /// No VM data or entire development .build directory is traversed.
    public static func capture(resources source: VPhoneResources, executable cli: URL) throws -> VPhoneCreateResourceSnapshot {
        try capture(resources: source, executable: cli, storage: FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-create-toolchains-\(geteuid())"), availableBytes: availableCapacity)
    }

    package static func capture(resources source: VPhoneResources, executable cli: URL, storage: URL,
                                availableBytes: (URL) throws -> Int64,
                                beforeCopy: ((URL, URL) throws -> Void)? = nil) throws -> VPhoneCreateResourceSnapshot {
        let fm = FileManager.default
        let cli = cli.resolvingSymlinksInPath()
        for required in source.coreRuntimeResources + [source.vphoned, cli, VPhoneResources.vmExecutable(executable: cli)] {
            var info = stat()
            guard stat(required.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw VPhoneMachineBindingError("Create resource is missing or is not a regular file: \(required.path)")
            }
        }
        if mkdir(storage.path, 0o700) != 0, errno != EEXIST { throw posix("create snapshot storage", storage) }
        var storageInfo = stat()
        guard lstat(storage.path, &storageInfo) == 0, storageInfo.st_mode & S_IFMT == S_IFDIR,
              storageInfo.st_uid == geteuid(), storageInfo.st_mode & 0o077 == 0 else {
            throw VPhoneMachineBindingError("Create snapshot storage must be a private owned directory: \(storage.path)")
        }
        let lock = open(storage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { throw posix("open snapshot storage", storage) }
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw posix("lock snapshot storage", storage) }
        let existing = try fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
        guard existing.count < maximumSnapshots else {
            throw VPhoneMachineBindingError("Create snapshot retention limit (\(maximumSnapshots)) reached at \(storage.path). Inspect retained manifests and explicitly remove snapshots that are no longer needed; no retained evidence was deleted.")
        }
        var roots: [(URL, String)] = []
        let contents = cli.deletingLastPathComponent().deletingLastPathComponent()
        if contents.lastPathComponent == "Contents", source.base.resolvingSymlinksInPath().standardizedFileURL == contents.appendingPathComponent("Resources").standardizedFileURL {
            // Preserve installed metadata, signatures and packaged native libraries.
            roots.append((contents, "VPhone.bundle/Contents"))
        } else {
            roots += [(cli, "VPhone.bundle/Contents/MacOS/vphone-cli"),
                      (VPhoneResources.vmExecutable(executable: cli), "VPhone.bundle/Contents/MacOS/vphone-vm")]
            for name in ["scripts", "dependencies", "requirements.txt", "debs.list", "README.md", ".tools/bin",
                         "tools/apfs_snap_rename.py", ".build/guest-components-v2/stage", "build-dependencies.json"] {
                let url = source.base.appendingPathComponent(name)
                if exists(url) { roots.append((url, "VPhone.bundle/Contents/Resources/" + name)) }
            }
            roots.append((source.guestResources, "VPhone.bundle/Contents/Resources/guest-resources"))
            // SwiftPM/runtime siblings only; never copy the build directory itself.
            for url in try fm.contentsOfDirectory(at: cli.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                where url.pathExtension == "dylib" || url.pathExtension == "bundle" {
                roots.append((url, "VPhone.bundle/Contents/MacOS/" + url.lastPathComponent))
            }
        }
        let inputs = try inventory(roots)
        let total = inputs.reduce(Int64(0)) { $0 + $1.entry.bytes }
        let retainedBytes = try existing.reduce(Int64(0)) { total, url in
            // Bounded traversal; only this module's small manifest is read here.
            let data = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
            let value = try VPhoneCreateJSON.decoder.decode(Manifest.self, from: data)
            return total + value.bytes
        }
        guard total <= maximumBytes, retainedBytes <= maximumBytes - total else {
            throw VPhoneMachineBindingError("Create snapshot byte limit (\(maximumBytes)) would be exceeded at \(storage.path); no retained evidence was deleted")
        }
        guard try availableBytes(storage) >= total + (64 << 20) else {
            throw VPhoneMachineBindingError("Insufficient space for \(total) bytes of create resources plus 64 MiB reserve; no VM data was changed")
        }
        let id = UUID().uuidString.lowercased()
        let directory = storage.appendingPathComponent(id)
        guard mkdir(directory.path, 0o700) == 0 else { throw posix("create snapshot", directory) }
        var published = false
        defer {
            if !published {
                makeDirectoriesWritable(directory)
                try? fm.removeItem(at: directory)
            }
        }
        var remainingBytes = total
        for input in inputs {
            let output = directory.appendingPathComponent(input.entry.path)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            if input.entry.kind == "directory" {
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
            } else {
                try copy(input, to: output, remainingBytes: &remainingBytes, beforeCopy: beforeCopy)
            }
        }
        // Apply directory modes only after populating read-only source directories.
        for input in inputs.reversed() where input.entry.kind == "directory" {
            guard chmod(directory.appendingPathComponent(input.entry.path).path, mode_t(input.entry.mode)) == 0 else {
                throw posix("preserve snapshot mode", directory)
            }
        }
        guard try inventory(roots).map(\.entry) == inputs.map(\.entry) else {
            throw VPhoneMachineBindingError("Create resources changed while copying; retry with stable inputs")
        }
        let entries = try inventory([(directory.appendingPathComponent("VPhone.bundle"), "VPhone.bundle")]).map(\.entry)
        let digest = try digest(entries)
        let manifest = Manifest(schemaVersion: 1, snapshotId: id, sourceResourceBase: source.base.path,
            sourceExecutable: cli.path, snapshotPath: directory.path, sha256: digest, bytes: total, entries: entries,
            closureLimits: closureLimits,
            retention: "Successful and refused attempts release their copies; failed started attempts retain copies. At most 8 snapshots / 2 GiB are admitted. Retained evidence requires explicit cleanup. Temporary storage may be cleared by the OS.")
        try VPhoneCreateJSON.encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        published = true
        return VPhoneCreateResourceSnapshot(directory: directory, source: source, manifest: manifest)
    }

    private init(directory: URL, source: VPhoneResources, manifest: Manifest) {
        self.directory = directory
        self.manifest = manifest
        resources = source.rebasedForCreate(at: directory.appendingPathComponent("VPhone.bundle/Contents/Resources"))
        executable = directory.appendingPathComponent("VPhone.bundle/Contents/MacOS/vphone-cli")
    }

    deinit { if !retained { Self.removeCopy(directory) } }

    public func fingerprint() throws -> String {
        try Self.digest(Self.inventory([(directory.appendingPathComponent("VPhone.bundle"), "VPhone.bundle")]).map(\.entry))
    }

    public var evidence: [String: String] {
        ["resource_snapshot_sha256": manifest.sha256, "resource_snapshot_path": directory.path,
         "resource_snapshot_closure_limits": manifest.closureLimits.joined(separator: "; ")]
    }

    /// Called only after an attempt has been accepted under the checkpoint lock.
    public func recordAttempt(_ id: String, checkpointDirectory: URL) throws {
        retained = true
        let output = checkpointDirectory.appendingPathComponent("attempts/\(id)-toolchain.json")
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posix("record snapshot manifest", output) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: VPhoneCreateJSON.encoder.encode(manifest))
        try file.synchronize()
    }

    public func releaseAfterSuccess() {
        retained = false
        Self.removeCopy(directory)
    }

    private static func removeCopy(_ directory: URL) {
        // Serialize removal with quota reads, so another capture cannot observe
        // a partially removed manifest. This removes only this owned copy.
        let storage = directory.deletingLastPathComponent()
        let fd = open(storage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        makeDirectoriesWritable(directory)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func makeDirectoriesWritable(_ directory: URL) {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        _ = chmod(directory.path, info.st_mode | 0o700)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            makeDirectoriesWritable(directory.appendingPathComponent(name))
        }
    }

    private static func inventory(_ roots: [(URL, String)]) throws -> [Input] {
        var output: [Input] = []
        var totalBytes: Int64 = 0
        func visit(_ source: URL, _ relative: String, ancestors: Set<String>) throws {
            let resolved = source.resolvingSymlinksInPath()
            guard source.lastPathComponent != "Disk.img", resolved.lastPathComponent != "Disk.img" else {
                throw VPhoneMachineBindingError("A VM Disk.img cannot be included in a create resource snapshot: \(source.path)")
            }
            var info = stat()
            guard lstat(resolved.path, &info) == 0 else { throw posix("inspect resource", source) }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                let identity = "\(info.st_dev):\(info.st_ino)"
                guard !ancestors.contains(identity) else { throw VPhoneMachineBindingError("Resource directory link cycle: \(source.path)") }
                output.append(Input(source: resolved, entry: Entry(path: relative, kind: "directory", mode: UInt16(info.st_mode & 0o777), bytes: 0, sha256: nil), info: info))
                var ancestors = ancestors; ancestors.insert(identity)
                for name in try FileManager.default.contentsOfDirectory(atPath: resolved.path).sorted()
                    where name != "__pycache__" && name != ".git" && !name.hasSuffix(".pyc") {
                    try visit(resolved.appendingPathComponent(name), relative + "/" + name, ancestors: ancestors)
                }
            } else if type == S_IFREG {
                guard info.st_size >= 0, info.st_size <= maximumBytes - totalBytes else {
                    throw VPhoneMachineBindingError("Create resource byte limit exceeded before hashing: \(source.path)")
                }
                totalBytes += info.st_size
                let measured = try VPhoneCreateDigest.sha256(fileAt: resolved)
                var after = stat()
                guard lstat(resolved.path, &after) == 0, sameRevision(info, after) else {
                    throw VPhoneMachineBindingError("Resource changed while hashing: \(source.path)")
                }
                output.append(Input(source: resolved, entry: Entry(path: relative, kind: "file", mode: UInt16(info.st_mode & 0o777), bytes: measured.size, sha256: measured.digest), info: info))
            } else {
                throw VPhoneMachineBindingError("Unsupported resource node: \(source.path)")
            }
        }
        for (url, relative) in roots { try visit(url, relative, ancestors: []) }
        return output.sorted { $0.entry.path < $1.entry.path }
    }

    private static func copy(_ input: Input, to output: URL, remainingBytes: inout Int64,
                             beforeCopy: ((URL, URL) throws -> Void)?) throws {
        guard input.entry.bytes <= remainingBytes else {
            throw VPhoneMachineBindingError("Resource exceeds remaining snapshot byte budget: \(input.source.path)")
        }
        let fd = open(input.source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posix("open resource", input.source) }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? source.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, sameRevision(input.info, before) else {
            throw VPhoneMachineBindingError("Resource changed before copying: \(input.source.path); expected \(revisionDescription(input.info)); observed \(revisionDescription(before))")
        }
        let outFD = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(input.entry.mode))
        guard outFD >= 0 else { throw posix("create resource copy", output) }
        let target = FileHandle(fileDescriptor: outFD, closeOnDealloc: true)
        defer { try? target.close() }
        // Package-only synchronization point for deterministic source-change tests.
        try beforeCopy?(input.source, output)
        var hasher = SHA256()
        var copiedBytes: Int64 = 0
        while let bytes = try source.read(upToCount: 1 << 20), !bytes.isEmpty {
            let count = Int64(bytes.count)
            guard count <= input.entry.bytes - copiedBytes, count <= remainingBytes else {
                throw VPhoneMachineBindingError("Resource grew beyond its preflight size or snapshot byte budget while copying: \(input.source.path)")
            }
            try target.write(contentsOf: bytes)
            copiedBytes += count
            remainingBytes -= count
            hasher.update(data: bytes)
        }
        var after = stat()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard copiedBytes == input.entry.bytes, fstat(fd, &after) == 0,
              sameRevision(before, after), digest == input.entry.sha256 else {
            throw VPhoneMachineBindingError("Resource changed while copying: \(input.source.path)")
        }
        guard fchmod(outFD, mode_t(input.entry.mode)) == 0 else { throw posix("preserve resource mode", output) }
        try target.synchronize()
    }

    private static func digest(_ entries: [Entry]) throws -> String {
        VPhoneCreateDigest.sha256(try VPhoneCreateJSON.encoder.encode(entries))
    }

    private static func revisionDescription(_ info: stat) -> String {
        "dev=\(info.st_dev),ino=\(info.st_ino),mode=\(info.st_mode),size=\(info.st_size),mtime=\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec),ctime=\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    // ctime can change when a host scanner sets an xattr. The manifest freezes
    // content and rwx mode, not ownership, ACLs, xattrs or every transient write.
    // Final SHA and the second source inventory still validate copied content.
    private static func sameRevision(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }

    private static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    private static func availableCapacity(_ url: URL) throws -> Int64 {
        var value = statfs()
        guard statfs(url.path, &value) == 0 else { throw posix("read snapshot capacity", url) }
        return Int64(value.f_bavail) * Int64(value.f_bsize)
    }
    private static func posix(_ action: String, _ url: URL) -> VPhoneMachineBindingError {
        VPhoneMachineBindingError("\(action): \(url.path): \(String(cString: strerror(errno)))")
    }
}

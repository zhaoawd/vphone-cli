import CryptoKit
import Darwin
import Foundation

/// Recorded origins in launchpad.json. These fields do not establish the
/// running host/guest identity or authorize a guest update. Legacy files
/// have three fields; a missing kernel origin remains unknown.
public struct VPhoneMachineBinding: Codable, Equatable, Sendable {
    public let bundle: String
    public let guestEnvironment: String?
    public let kernel: String?
    public let bootChain: String?

    public enum Layer: String, Codable, CaseIterable, Sendable {
        case host, guestEnvironment, kernel, bootChain
    }

    public func replacingOrigin(_ layer: Layer, with version: String) throws -> Self {
        try Self(bundle: layer == .host ? version : bundle,
                 guestEnvironment: layer == .guestEnvironment ? version : guestEnvironment,
                 kernel: layer == .kernel ? version : kernel,
                 bootChain: layer == .bootChain ? version : bootChain)
    }

    public enum Read: Equatable, Sendable {
        case missing
        case invalid(String)
        case loaded(VPhoneMachineBinding)
    }

    public static let fileName = "launchpad.json"

    /// True when any recorded guest/kernel/bootChain component origin differs
    /// from the selected host Core Bundle version.
    public var hasMixedVersions: Bool {
        [guestEnvironment, kernel, bootChain].contains { $0.map { $0 != bundle } ?? false }
    }

    public init(bundle: String, guestEnvironment: String? = nil, kernel: String? = nil, bootChain: String? = nil) throws {
        guard [bundle, guestEnvironment, kernel, bootChain].allSatisfy({ $0.map(VPhoneCoreBundleVersion.isStoreName) ?? true }) else {
            throw VPhoneMachineBindingError("Invalid Core Bundle origin in launchpad.json")
        }
        self.bundle = bundle
        self.guestEnvironment = guestEnvironment
        self.kernel = kernel
        self.bootChain = bootChain
    }

    /// Changes only the recorded host selection. It performs no file write,
    /// executable selection, kernel update or guest environment replacement.
    public func replacingHost(with bundle: String) throws -> Self {
        try replacingOrigin(.host, with: bundle)
    }

    // MARK: - Snapshots

    /// Path to `Snapshots/<name>/launchpad.json` inside `machine`, or nil when
    /// `name` is invalid or `machine`, `Snapshots`, or `Snapshots/<name>` is not
    /// a real directory (never following symbolic links).
    public static func url(for machine: URL, snapshot name: String) -> URL? {
        guard (try? VPhoneMachineSnapshots.requireValidName(name)) != nil,
              !name.contains("..")
        else {
            return nil
        }
        let snapshots = machine.appendingPathComponent(VPhoneMachineSnapshots.directoryName, isDirectory: true)
        let folder = snapshots.appendingPathComponent(name, isDirectory: true)
        for directory in [machine, snapshots, folder] {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                return nil
            }
        }
        return folder.appendingPathComponent(fileName)
    }

    /// Loads the binding sidecar saved in `Snapshots/<name>/launchpad.json`,
    /// returning nil when absent, linked, or invalid.
    public static func load(_ machine: URL, snapshot name: String) -> VPhoneMachineBinding? {
        guard let sidecar = url(for: machine, snapshot: name) else { return nil }
        return try? readSidecar(at: sidecar)
    }

    /// Saves this binding to `Snapshots/<name>/launchpad.json` without following
    /// symbolic links. Requires the snapshot directory to exist.
    public func save(to machine: URL, snapshot name: String) throws {
        guard let sidecar = Self.url(for: machine, snapshot: name) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSFilePathErrorKey: machine
                    .appendingPathComponent(VPhoneMachineSnapshots.directoryName)
                    .appendingPathComponent(name).path,
            ])
        }
        try writeAtomically(to: sidecar)
    }

    /// Reconciles the four-layer binding after reverting a machine to a snapshot.
    /// The host Core Bundle (`bundle`) remains the currently selected one, while
    /// `guestEnvironment`, `kernel` and `bootChain` come from the snapshot's
    /// saved sidecar (or become nil / Unknown when the snapshot has no valid sidecar).
    public func reverted(to saved: VPhoneMachineBinding?) -> VPhoneMachineBinding {
        (try? VPhoneMachineBinding(
            bundle: bundle,
            guestEnvironment: saved?.guestEnvironment,
            kernel: saved?.kernel,
            bootChain: saved?.bootChain
        )) ?? self
    }

    static func reconcileAfterSnapshotRevert(machine: URL, snapshot name: String) {
        guard let current = try? transactionSnapshot(machine)?.binding else { return }
        let saved = load(machine, snapshot: name)
        let next = current.reverted(to: saved)
        try? next.writeAtomically(to: machine.appendingPathComponent(fileName))
    }

    private static func readSidecar(at url: URL) throws -> VPhoneMachineBinding {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw VPhoneMachineBindingError("Cannot open snapshot launchpad.json without following links")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat(), after = stat(), current = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 65536 else {
            throw VPhoneMachineBindingError("snapshot launchpad.json must be a regular file of 1...65536 bytes")
        }
        let bytes = try file.read(upToCount: 65537) ?? Data()
        guard bytes.count == Int(before.st_size), bytes.count <= 65536,
              fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              sameRevision(before, after), sameRevision(after, current) else {
            throw VPhoneMachineBindingError("snapshot launchpad.json changed while reading")
        }
        let decoded = try JSONDecoder().decode(Self.self, from: bytes)
        return try Self(
            bundle: decoded.bundle,
            guestEnvironment: decoded.guestEnvironment,
            kernel: decoded.kernel,
            bootChain: decoded.bootChain
        )
    }

    private func writeAtomically(to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(Self.fileName)-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try output.write(contentsOf: encoder.encode(self))
        try output.synchronize()
        try output.close()
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// One validated file read. Consumers can freeze a selection before work,
    /// then refuse a changed binding rather than selecting the current default.
    public struct Snapshot: Equatable, Sendable {
        public let binding: VPhoneMachineBinding
        public let sha256: String
        private let device: Int32
        private let inode: UInt64
        private let modifiedSeconds: Int
        private let modifiedNanoseconds: Int
        private let changedSeconds: Int
        private let changedNanoseconds: Int

        fileprivate init(binding: VPhoneMachineBinding, bytes: Data, info: stat) {
            self.binding = binding
            sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            device = info.st_dev
            inode = UInt64(info.st_ino)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }

        public func matches(_ machine: URL) -> Bool {
            guard let current = try? VPhoneMachineBinding.snapshot(machine) else { return false }
            return self == current
        }
    }

    public static func snapshot(_ machine: URL) throws -> Snapshot? {
        try snapshot(machine, afterRead: {})
    }

    // Deterministic test seam: a real same-size in-place write between read and fstat.
    package static func snapshot(_ machine: URL, afterRead: () throws -> Void) throws -> Snapshot? {
        try withCommittedOriginsRead(machine) { try transactionSnapshot(machine, afterRead: afterRead) }
    }

    /// Read-only package consumers share the same pending publication boundary.
    package static func withCommittedOriginsRead<T>(_ machine: URL, body: () throws -> T) throws -> T {
        let before = try committedDirectoryRevision(machine)
        let result = try body()
        let after = try committedDirectoryRevision(machine)
        guard sameRevision(before, after) else {
            throw VPhoneMachineBindingError("VM directory changed while reading origins")
        }
        return result
    }

    /// Only the transaction implementation may inspect transitional metadata.
    /// This raw snapshot carries no committed-state or source qualification.
    package static func transactionSnapshot(_ machine: URL) throws -> Snapshot? {
        try transactionSnapshot(machine, afterRead: {})
    }

    private static func committedDirectoryRevision(_ machine: URL) throws -> stat {
        var directory = stat(), pending = stat()
        guard lstat(machine.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR else {
            throw VPhoneMachineBindingError("Cannot inspect VM directory for committed origins")
        }
        guard lstat(machine.appendingPathComponent(".firmware-transaction").path, &pending) != 0,
              errno == ENOENT else {
            throw VPhoneMachineBindingError("Pending firmware transaction; component origins are unavailable until recovery")
        }
        guard !(try FileManager.default.contentsOfDirectory(atPath: machine.path)).contains(where: { $0.hasPrefix(".cfw_disk.") }) else {
            throw VPhoneMachineBindingError("Pending CFW disk transaction; component origins are unavailable until recovery")
        }
        return directory
    }

    private static func transactionSnapshot(_ machine: URL, afterRead: () throws -> Void) throws -> Snapshot? {
        let url = machine.appendingPathComponent("launchpad.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw VPhoneMachineBindingError("Cannot open launchpad.json without following links")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat(), after = stat(), current = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 65536 else {
            throw VPhoneMachineBindingError("launchpad.json must be a regular file of 1...65536 bytes")
        }
        let bytes = try file.read(upToCount: 65537) ?? Data()
        try afterRead()
        guard bytes.count == Int(before.st_size), bytes.count <= 65536,
              fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              sameRevision(before, after), sameRevision(after, current) else {
            throw VPhoneMachineBindingError("launchpad.json changed while reading")
        }
        let decoded = try JSONDecoder().decode(Self.self, from: bytes)
        let checked = try Self(bundle: decoded.bundle, guestEnvironment: decoded.guestEnvironment,
                               kernel: decoded.kernel, bootChain: decoded.bootChain)
        return Snapshot(binding: checked, bytes: bytes, info: after)
    }

    private static func sameRevision(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    public static func load(_ machine: URL) -> Read {
        do {
            guard let value = try snapshot(machine) else { return .missing }
            return .loaded(value.binding)
        } catch { return .invalid("Invalid launchpad.json: \(error.localizedDescription)") }
    }
}

public struct VPhoneMachineBindingError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

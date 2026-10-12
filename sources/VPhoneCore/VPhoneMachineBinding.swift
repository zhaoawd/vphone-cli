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

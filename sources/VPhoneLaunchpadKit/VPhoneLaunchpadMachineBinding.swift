import Darwin
import Foundation

/// Recorded origins in launchpad.json. These fields do not establish the
/// running host/guest identity or authorize a guest update. Legacy files
/// have three fields; a missing kernel origin remains unknown.
public struct VPhoneLaunchpadMachineBinding: Codable, Equatable, Sendable {
    public let bundle: String
    public let guestEnvironment: String?
    public let kernel: String?
    public let bootChain: String?

    public enum Read: Equatable, Sendable {
        case missing
        case invalid(String)
        case loaded(VPhoneLaunchpadMachineBinding)
    }

    public init(bundle: String, guestEnvironment: String? = nil, kernel: String? = nil, bootChain: String? = nil) throws {
        guard [bundle, guestEnvironment, kernel, bootChain].allSatisfy({ $0.map(VPhoneLaunchpadCoreBundleVersion.isStoreName) ?? true }) else {
            throw VPhoneLaunchpadError("Invalid Core Bundle origin in launchpad.json")
        }
        self.bundle = bundle
        self.guestEnvironment = guestEnvironment
        self.kernel = kernel
        self.bootChain = bootChain
    }

    /// Changes only the recorded host selection. It performs no file write,
    /// executable selection, kernel update or guest environment replacement.
    public func replacingHost(with bundle: String) throws -> Self {
        try Self(bundle: bundle, guestEnvironment: guestEnvironment, kernel: kernel, bootChain: bootChain)
    }

    public static func load(_ machine: VPhoneLaunchpadMachinePath) -> Read {
        let url = machine.url.appendingPathComponent("launchpad.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .invalid("Cannot open launchpad.json without following links") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 65536 else { return .invalid("launchpad.json must be a regular file of 1...65536 bytes") }
        do {
            let bytes = try file.read(upToCount: 65537) ?? Data()
            guard bytes.count == Int(info.st_size), bytes.count <= 65536 else { return .invalid("launchpad.json changed while reading") }
            let decoded = try JSONDecoder().decode(Self.self, from: bytes)
            let checked = try Self(bundle: decoded.bundle, guestEnvironment: decoded.guestEnvironment, kernel: decoded.kernel, bootChain: decoded.bootChain)
            return .loaded(checked)
        } catch { return .invalid("Invalid launchpad.json: \(error.localizedDescription)") }
    }
}

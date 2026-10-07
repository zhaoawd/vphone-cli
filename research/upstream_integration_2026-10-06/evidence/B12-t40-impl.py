from pathlib import Path
p=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineBinding.swift');s=p.read_text().replace('import Darwin','import CryptoKit\nimport Darwin',1);start=s.index('    public static func load(')
s=s[:start]+r'''    /// One validated file read. Consumers can freeze a selection before work,
    /// then refuse a changed binding rather than selecting the current default.
    public struct Snapshot: Equatable, Sendable {
        public let binding: VPhoneLaunchpadMachineBinding
        public let sha256: String
        private let device: Int32
        private let inode: UInt64

        fileprivate init(binding: VPhoneLaunchpadMachineBinding, bytes: Data, info: stat) {
            self.binding = binding
            sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            device = info.st_dev
            inode = UInt64(info.st_ino)
        }

        public func matches(_ machine: VPhoneLaunchpadMachinePath) -> Bool {
            guard let current = try? VPhoneLaunchpadMachineBinding.snapshot(machine) else { return false }
            return self == current
        }
    }

    public static func snapshot(_ machine: VPhoneLaunchpadMachinePath) throws -> Snapshot? {
        try snapshot(machine, afterRead: {})
    }

    // Deterministic test seam: a real same-size in-place write between read and fstat.
    static func snapshot(_ machine: VPhoneLaunchpadMachinePath, afterRead: () throws -> Void) throws -> Snapshot? {
        let url = machine.url.appendingPathComponent("launchpad.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw VPhoneLaunchpadError("Cannot open launchpad.json without following links")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat(), after = stat(), current = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 65536 else {
            throw VPhoneLaunchpadError("launchpad.json must be a regular file of 1...65536 bytes")
        }
        let bytes = try file.read(upToCount: 65537) ?? Data()
        try afterRead()
        guard bytes.count == Int(before.st_size), bytes.count <= 65536,
              fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              sameRevision(before, after), sameRevision(after, current) else {
            throw VPhoneLaunchpadError("launchpad.json changed while reading")
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

    public static func load(_ machine: VPhoneLaunchpadMachinePath) -> Read {
        do {
            guard let value = try snapshot(machine) else { return .missing }
            return .loaded(value.binding)
        } catch { return .invalid("Invalid launchpad.json: \(error.localizedDescription)") }
    }
}
''';p.write_text(s)

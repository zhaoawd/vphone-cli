import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import VPhoneBundleStore
import VPhoneCore

/// A source is acquired only from the actual Store CLI. The root producer
/// passes its shared Store lease as stdin before the shell acquires the VM lock.
enum VPhoneCFWTrustedProducer {
    // The proof includes the complete effect blob index, not just a receipt.
    static let maximumAttestationBytes = 16 * 1024 * 1024
    struct Source: Encodable, Equatable {
        let schemaVersion = 1
        let producer = "current-verified-core-bundle-cli"
        let version: String
        let executable: String
        let executableSHA256: String
        let resourceBase: String
        let archiveSHA256: String
        let cliCDHash: String

        func json() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }

    static func source(executable: URL, receipt: VPhoneBundleReceipt) throws -> Source {
        guard VPhoneCoreBundleVersion.supportsTargetFeatures(receipt.version),
              executable.standardizedFileURL == VPhoneResources.runningExecutable().standardizedFileURL,
              executable == executable.resolvingSymlinksInPath(),
              let cdhash = receipt.cdhashes[VPhoneBundleExecutable.cli.rawValue] else {
            throw ValidationError("Guest origin requires the actual current verified Store CLI")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        return Source(version: receipt.version, executable: executable.path, executableSHA256: digest,
            resourceBase: VPhoneResources.resolve(executablePath: executable.path).base.path,
            archiveSHA256: receipt.sha256, cliCDHash: cdhash.lowercased())
    }

    static func withLease<T>(machine: URL, body: ([String: String], FileHandle) throws -> T) throws -> T {
        guard geteuid() == 0, let expected = try VPhoneMachineBinding.snapshot(machine) else {
            throw ValidationError("Qualified Guest installation requires root and a host-bound VM")
        }
        return try VPhoneCoreBundleStore().withExecutableLease(version: expected.binding.bundle, executable: .cli) {
            executable, receipt, input, recheck in
            let proof = try source(executable: executable, receipt: receipt)
            try recheck()
            let result = try body(["VPHONE_CFW_ORIGIN_SOURCE": proof.json(),
                "VPHONE_EXPECTED_BINDING_SHA256": expected.sha256,
                "VPHONE_EXPECTED_CORE_BUNDLE": expected.binding.bundle], input)
            try recheck()
            return result
        }
    }

    static func verify(version: String, requireLease: Bool) throws -> Source {
        let store = VPhoneCoreBundleStore()
        if requireLease {
            let parents = Dictionary(VPhoneProcessInfo.table().map { ($0.pid, $0.ppid) }, uniquingKeysWith: { _, current in current })
            guard geteuid() == 0, qualifiedAncestor(start: getppid(), executable: VPhoneResources.runningExecutable(),
                parents: parents, identity: VPhoneProcessInfo.identity, arguments: VPhoneProcessInfo.arguments) else {
                throw ValidationError("Guest source verification requires the active root producer or recovery process")
            }
            let (executable, receipt) = try store.inheritedExecutable(version: version, executable: .cli,
                                                                       descriptor: STDIN_FILENO)
            return try source(executable: executable, receipt: receipt)
        }
        return try store.withRevalidatedExecutable(version: version, executable: .cli) { executable, recheck in
            let receipt = try store.verify(version: version)
            let result = try source(executable: executable, receipt: receipt)
            try recheck()
            return result
        }
    }

    static func qualifiedAncestor(start: pid_t, executable: URL, parents: [pid_t: pid_t],
        identity: (pid_t) -> VPhoneProcessIdentity?, arguments: (pid_t) -> [String]?) -> Bool {
        var pid = start
        var seen = Set<pid_t>()
        for _ in 0..<64 {
            guard pid > 1, seen.insert(pid).inserted else { return false }
            if let before = identity(pid), before.uid == 0, !before.isZombie,
               let args = arguments(pid), args.count >= 3,
               URL(fileURLWithPath: args[0]).standardizedFileURL == executable.standardizedFileURL,
               args[1] == "cfw",
               ((args[2] == "install" && args.contains("--qualify-origin")) || args[2] == "recover-origin"),
               identity(pid) == before {
                return true
            }
            guard let parent = parents[pid] else { return false }
            pid = parent
        }
        return false
    }

    static func requireAttestation(_ url: URL, sha256: String, owner: uid_t = 0) throws {
        guard url.lastPathComponent == "guest-origin-attestation.json", url == url.resolvingSymlinksInPath(),
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ValidationError("Invalid Guest producer attestation path or digest")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ValidationError("Guest producer attestation is unavailable") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == owner,
              before.st_nlink == 1, before.st_mode & 0o7777 == 0o444,
              (1...off_t(maximumAttestationBytes)).contains(before.st_size) else {
            throw ValidationError("Guest producer attestation must retain immutable root ownership")
        }
        if let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
                  errno == EINVAL else { throw ValidationError("Guest producer attestation cannot have an extended ACL") }
        } else if errno != ENOENT { throw ValidationError("Guest producer attestation ACL is unreadable") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            .read(upToCount: maximumAttestationBytes + 1) ?? Data()
        var after = stat(), named = stat()
        func matches(_ info: stat) -> Bool {
            info.st_dev == before.st_dev && info.st_ino == before.st_ino && info.st_uid == before.st_uid &&
            info.st_gid == before.st_gid && info.st_mode == before.st_mode && info.st_nlink == before.st_nlink &&
            info.st_size == before.st_size && info.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec &&
            info.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec && info.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec &&
            info.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        }
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0, matches(after), matches(named),
              data.count == before.st_size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw ValidationError("Guest producer attestation changed or differs from the sealed journal")
        }
    }

    static func requireDefaultResources(projectRoot: String?, environment: [String: String]) throws {
        let overrides = ["VPHONE_PYTHON", "VPHONE_VENV_DIR", "VPHONE_HOST_PYTHON", "VPHONE_GUEST_COMPONENTS", "VPHONE_API_DAEMON"]
        guard projectRoot == nil, overrides.allSatisfy({ environment[$0] == nil }) else {
            throw ValidationError("Qualified Guest installation cannot override its producer resources or Python runtime")
        }
    }
}

struct VPhoneCFWVerifyOriginSourceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify-origin-source", shouldDisplay: false)
    @Argument var version: String
    @Flag(name: .customLong("require-lease")) var requireLease = false
    @Option var attestation: String?
    @Option(name: .customLong("attestation-sha256")) var attestationSha256: String?

    func run() throws {
        guard (attestation == nil) == (attestationSha256 == nil) else {
            throw ValidationError("Guest attestation requires both path and SHA-256")
        }
        if let attestation, let attestationSha256 {
            try VPhoneCFWTrustedProducer.requireAttestation(URL(fileURLWithPath: attestation), sha256: attestationSha256)
        }
        print(try VPhoneCFWTrustedProducer.verify(version: version, requireLease: requireLease).json())
    }
}

import CryptoKit
import Darwin
import Foundation
import VPhoneArchiveKit

/// Shared by the explicit sudo CLI and the future authorized helper service.
/// No environment override, executable path, or alternate store is accepted by
/// the production initializer. XPC caller authorization belongs at the service boundary.
public struct VPhoneCoreBundleStore: Sendable {
    public static let root = URL(fileURLWithPath: "/Library/Application Support/vphone-launchpad/Bundles")
    let root: URL
    let anchor: URL
    let owner: uid_t
    let group: gid_t
    static let maximumArchiveBytes: UInt64 = 8 << 30
    static let maximumExpandedBytes: Int64 = 16 << 30

    public init() {
        root = Self.root
        anchor = URL(fileURLWithPath: "/")
        owner = 0
        group = 0
    }

    // Only @testable clients can use a private temporary directory and current UID.
    init(testRoot: URL) {
        root = testRoot.resolvingSymlinksInPath()
        anchor = root.deletingLastPathComponent()
        owner = geteuid()
        group = getegid()
    }

    // MARK: - Installation

    /// Installs from a regular-file descriptor, never reopening the caller's path.
    /// The expected digest is asserted by the authorized caller, not by this module.
    public func install(version: String, archive: FileHandle, sha256: String) throws -> VPhoneBundleReceipt {
        try VPhoneBundleVersion.require(version)
        guard geteuid() == owner else { throw VPhoneBundleStoreError("Core Bundle installation requires root (sudo).") }
        let expected = sha256.lowercased()
        try requireHex(expected, length: 64)
        try prepareRoot()
        return try withLock(exclusive: true) {
            let destination = directory(version)
            var existing = stat()
            guard lstat(destination.path, &existing) != 0, errno == ENOENT else {
                throw VPhoneBundleStoreError("Core Bundle version already exists: \(version). Existing installations are never replaced.")
            }
            let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
            try makeDirectory(staging, mode: 0o700)
            defer { try? FileManager.default.removeItem(at: staging) }
            let snapshot = staging.appendingPathComponent("archive")
            let actual = try copyAndHash(archive, to: snapshot)
            guard actual == expected else { throw VPhoneBundleStoreError("Core Bundle archive SHA-256 mismatch.") }
            try inspectArchive(snapshot)
            let extracted = staging.appendingPathComponent("extracted")
            try makeDirectory(extracted, mode: 0o700)
            try VPhoneArchiveExtractor.extract(snapshot, into: extracted, options: .intoHostDirectory)
            let bundle = extracted.appendingPathComponent("VPhone.bundle")
            try secureTree(bundle, normalize: true)
            try requireBundleLayout(bundle, version: version)
            try VPhoneBundleCodeSignature.verify(bundle)
            var hashes: [String: String] = [:]
            for executable in VPhoneBundleExecutable.allCases {
                hashes[executable.rawValue] = try VPhoneBundleCodeSignature.cdhash(executableURL(bundle, executable))
            }
            let receipt = VPhoneBundleReceipt(version: version, sha256: actual, installedAt: Date(), cdhashes: hashes)
            let publication = staging.appendingPathComponent("publication")
            try makeDirectory(publication, mode: 0o755)
            try FileManager.default.moveItem(at: bundle, to: publication.appendingPathComponent("VPhone.bundle"))
            let receiptURL = publication.appendingPathComponent("receipt.json")
            let fd = open(receiptURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw failure("create receipt", receiptURL) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try output.write(contentsOf: receipt.encoded())
            try output.synchronize()
            try output.close()
            try secureTree(publication, normalize: true)
            // One atomic, exclusive rename publishes both bundle and receipt.
            guard renamex_np(publication.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw failure("publish Core Bundle", destination)
            }
            return receipt
        }
    }

    // MARK: - Verification and use

    public func verify(version: String) throws -> VPhoneBundleReceipt {
        try VPhoneBundleVersion.require(version)
        try requireRoot()
        return try withLock(exclusive: false) { try verifiedReceipt(version) }
    }

    /// The callback executes while the store lock is held. Consumers must wait
    /// for their child operation inside the callback, rather than retain this URL.
    public func withVerifiedExecutable<T>(version: String, executable: VPhoneBundleExecutable,
                                          body: (URL) throws -> T) throws -> T {
        try VPhoneBundleVersion.require(version)
        try requireRoot()
        return try withLock(exclusive: false) {
            _ = try verifiedReceipt(version)
            return try body(executableURL(directory(version).appendingPathComponent("VPhone.bundle"), executable))
        }
    }

    private func verifiedReceipt(_ version: String) throws -> VPhoneBundleReceipt {
        let directory = directory(version)
        try secureTree(directory, normalize: false)
        let receiptURL = directory.appendingPathComponent("receipt.json")
        let info = try requireEntry(receiptURL, type: S_IFREG)
        guard info.st_size > 0, info.st_size <= 65536 else {
            throw VPhoneBundleStoreError("Invalid Core Bundle receipt size \(info.st_size) (1–65536 bytes): \(receiptURL.path)")
        }
        let receipt: VPhoneBundleReceipt
        do { receipt = try VPhoneBundleReceipt.decode(Data(contentsOf: receiptURL)) } catch {
            throw VPhoneBundleStoreError("Invalid Core Bundle receipt: expected JSON with version, sha256, installedAt and cdhashes: \(receiptURL.path)")
        }
        try Self.requireReceipt(receipt, version: version)
        let bundle = directory.appendingPathComponent("VPhone.bundle")
        try requireBundleLayout(bundle, version: version)
        try VPhoneBundleCodeSignature.verify(bundle)
        for executable in VPhoneBundleExecutable.allCases {
            let expected = receipt.cdhashes[executable.rawValue]!
            let actual = try VPhoneBundleCodeSignature.cdhash(executableURL(bundle, executable))
            guard actual == expected else {
                throw VPhoneBundleStoreError("Installed \(executable.rawValue) cdhash \(actual) differs from its receipt (\(expected)).")
            }
        }
        return receipt
    }

    /// Receipt fields checked before any signature work, one reason per failure.
    static func requireReceipt(_ receipt: VPhoneBundleReceipt, version: String) throws {
        guard receipt.version == version else {
            throw VPhoneBundleStoreError("Core Bundle receipt version \(VPhoneBundleVersion.quoted(receipt.version)) does not match installed version \(version).")
        }
        let required = VPhoneBundleExecutable.allCases.map(\.rawValue).sorted()
        guard receipt.cdhashes.keys.sorted() == required else {
            throw VPhoneBundleStoreError("Core Bundle receipt cdhashes must name exactly \(required.joined(separator: ", ")); found: \(receipt.cdhashes.keys.sorted().map(VPhoneBundleVersion.quoted).joined(separator: ", ")).")
        }
        guard isHex(receipt.sha256, length: 64) else {
            throw VPhoneBundleStoreError("Core Bundle receipt sha256 is not 64 lowercase hexadecimal digits.")
        }
        for name in required where !isHex(receipt.cdhashes[name]!, length: 40) {
            throw VPhoneBundleStoreError("Core Bundle receipt cdhash for \(name) is not 40 lowercase hexadecimal digits.")
        }
    }

    private func requireBundleLayout(_ bundle: URL, version: String) throws {
        for path in ["", "Contents", "Contents/MacOS", "Contents/Resources"] {
            _ = try requireEntry(path.isEmpty ? bundle : bundle.appendingPathComponent(path), type: S_IFDIR)
        }
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let info = try requireEntry(plist, type: S_IFREG)
        guard info.st_size > 0, info.st_size <= 1 << 20 else { throw VPhoneBundleStoreError("Invalid Core Bundle Info.plist size.") }
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        guard let properties = value as? [String: Any], let actual = properties["CFBundleShortVersionString"] as? String else {
            throw VPhoneBundleStoreError("Core Bundle Info.plist version mismatch: CFBundleShortVersionString is missing.")
        }
        guard actual == VPhoneBundleVersion.release(of: version) else {
            throw VPhoneBundleStoreError("Core Bundle Info.plist version mismatch: CFBundleShortVersionString \(VPhoneBundleVersion.quoted(actual)), requested \(version).")
        }
        try VPhoneBundleVersion.require(actual)
        for name in VPhoneBundleExecutable.allCases.map(\.rawValue) + ["vphone-escalator"] {
            let file = bundle.appendingPathComponent("Contents/MacOS/\(name)")
            let info = try requireEntry(file, type: S_IFREG)
            guard info.st_mode & 0o111 != 0 else { throw VPhoneBundleStoreError("Not executable: \(file.path)") }
            try VPhoneMachOArchitectures.requireAppleSilicon(file)
        }
    }

    // MARK: - Archive boundary

    private func copyAndHash(_ source: FileHandle, to destination: URL) throws -> String {
        var info = stat()
        guard fstat(source.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, UInt64(info.st_size) <= Self.maximumArchiveBytes else {
            throw VPhoneBundleStoreError("Archive must be a nonempty regular file of at most 8 GiB.")
        }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("create archive snapshot", destination) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var hasher = SHA256()
        var offset: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = pread(source.fileDescriptor, &buffer, buffer.count, off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw VPhoneBundleStoreError("Unable to read archive descriptor.") }
            if count == 0 { break }
            offset += UInt64(count)
            guard offset <= Self.maximumArchiveBytes else { throw VPhoneBundleStoreError("Archive size limit exceeded.") }
            let data = Data(buffer.prefix(count))
            hasher.update(data: data)
            try output.write(contentsOf: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func inspectArchive(_ archive: URL) throws {
        let entries = try VPhoneArchiveReader.entries(of: archive, maximumEntries: 100_000)
        var paths = Set<String>()
        var total: Int64 = 0
        for entry in entries {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.first == "VPhone.bundle", !parts.contains(".."), !parts.contains("."), !parts.contains(""),
                  paths.insert(path).inserted, entry.hardlinkTarget == nil,
                  [S_IFREG, S_IFDIR, S_IFLNK].contains(entry.fileType),
                  entry.mode & (S_ISUID | S_ISGID | S_ISVTX) == 0,
                  entry.size >= 0, entry.size <= Self.maximumExpandedBytes - total else {
                throw VPhoneBundleStoreError("Unsafe or oversized archive member: \(entry.path)")
            }
            total += entry.size
            if entry.isSymlink {
                guard let target = entry.linkTarget,
                      Self.linkStaysInside(path: String(path.dropFirst("VPhone.bundle/".count)), target: target),
                      path != "VPhone.bundle" else {
                    throw VPhoneBundleStoreError("Unsafe symbolic link: \(entry.path)")
                }
            }
        }
    }

    /// Leading climbs may traverse only known real parent directories. A climb
    /// after a named component could cross a second symlink and is refused.
    static func linkStaysInside(path: String, target: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { return false }
        var depth = path.split(separator: "/").count - 1
        var descended = false
        for part in target.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !descended, depth > 0 else { return false }
                depth -= 1
            } else {
                descended = true
                depth += 1
            }
        }
        return true
    }

    // MARK: - Root-owned filesystem

    private func directory(_ version: String) -> URL { root.appendingPathComponent(version) }
    private func executableURL(_ bundle: URL, _ name: VPhoneBundleExecutable) -> URL {
        bundle.appendingPathComponent("Contents/MacOS/\(name.rawValue)")
    }

    private func prepareRoot() throws {
        try checkAncestors(create: true)
    }

    private func requireRoot() throws {
        try checkAncestors(create: false)
    }

    private func checkAncestors(create: Bool) throws {
        var chain = [root]
        while chain.last!.path != anchor.path {
            let parent = chain.last!.deletingLastPathComponent()
            guard parent.path != chain.last!.path else { throw VPhoneBundleStoreError("Invalid store anchor.") }
            chain.append(parent)
        }
        for url in chain.reversed() {
            var info = stat()
            if lstat(url.path, &info) != 0, errno == ENOENT, create {
                try makeDirectory(url, mode: 0o755)
            }
            _ = try requireEntry(url, type: S_IFDIR)
        }
    }

    private func makeDirectory(_ url: URL, mode: mode_t) throws {
        guard mkdir(url.path, mode) == 0, chown(url.path, owner, group) == 0,
              chmod(url.path, mode) == 0 else { throw failure("create directory", url) }
        try requireNoACL(url)
    }

    private func withLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        let url = root.appendingPathComponent(".store.lock")
        let flags = O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var fd: Int32
        if exclusive {
            fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | flags, 0o644)
            if fd >= 0 {
                guard fchmod(fd, 0o644) == 0 else { close(fd); throw failure("set lock permissions", url) }
            } else if errno == EEXIST {
                fd = open(url.path, O_RDWR | flags)
            }
        } else {
            fd = open(url.path, O_RDONLY | flags)
        }
        guard fd >= 0 else { throw failure("open store lock", url) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
              info.st_nlink == 1, info.st_mode & 0o7022 == 0 else { throw VPhoneBundleStoreError("Unsafe store lock.") }
        try requireNoACL(url)
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            throw VPhoneBundleStoreError("Core Bundle store is busy.")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Read-only: reports the first property that fails and never repairs it.
    @discardableResult
    private func requireEntry(_ url: URL, type: mode_t) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw failure("inspect", url) }
        let expected = type == S_IFDIR ? "directory" : "regular file"
        let reason: String? = if info.st_mode & S_IFMT != type {
            "type is not a \(expected)\(info.st_mode & S_IFMT == S_IFLNK ? " (symbolic link)" : "")"
        } else if info.st_uid != owner {
            "owner uid \(info.st_uid), expected \(owner)"
        } else if info.st_mode & 0o7022 != 0 {
            "mode \(String(info.st_mode & 0o7777, radix: 8)) has group/other write or setuid/setgid/sticky bits"
        } else if type == S_IFREG, info.st_nlink != 1 {
            "\(info.st_nlink) hard links, expected 1"
        } else { nil }
        if let reason { throw VPhoneBundleStoreError("Unsafe ownership, type, links, or permissions: \(url.path): \(reason)") }
        try requireNoACL(url)
        return info
    }

    private func requireNoACL(_ url: URL) throws {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            // Darwin may return ENOENT for an existing object without an ACL.
            // Distinguish it from a missing entry before accepting the result.
            let error = errno
            var info = stat()
            if error == ENOENT, lstat(url.path, &info) == 0 { return }
            throw failure("read ACL", url)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
            throw VPhoneBundleStoreError("Extended ACLs are not accepted in the Core Bundle store: \(url.path)")
        }
    }

    private func secureTree(_ tree: URL, normalize: Bool) throws {
        // Inspect real directories recursively; never traverse a symbolic link.
        func visit(_ url: URL, relative: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw failure("inspect tree", url) }
            let type = info.st_mode & S_IFMT
            let reason: String? = if !(type == S_IFDIR || type == S_IFREG || type == S_IFLNK) {
                "not a directory, regular file or symbolic link"
            } else if info.st_uid != owner {
                "owner uid \(info.st_uid), expected \(owner)"
            } else if info.st_mode & 0o7000 != 0 {
                "setuid/setgid/sticky mode \(String(info.st_mode & 0o7777, radix: 8))"
            } else if type == S_IFREG, info.st_nlink != 1 {
                "\(info.st_nlink) hard links, expected 1"
            } else { nil }
            if let reason { throw VPhoneBundleStoreError("Unsafe bundle entry: \(url.path): \(reason)") }
            try requireNoACL(url)
            if type == S_IFLNK {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                guard !relative.isEmpty, Self.linkStaysInside(path: relative, target: target) else {
                    throw VPhoneBundleStoreError("Unsafe bundle symbolic link: \(url.path)")
                }
            } else if normalize {
                let mode: mode_t = type == S_IFDIR || info.st_mode & 0o111 != 0 ? 0o755 : 0o644
                guard chown(url.path, owner, group) == 0, chmod(url.path, mode) == 0 else {
                    throw failure("normalize bundle permissions", url)
                }
            } else if info.st_mode & 0o022 != 0 {
                throw VPhoneBundleStoreError("Writable installed bundle entry: \(url.path): mode \(String(info.st_mode & 0o7777, radix: 8))")
            }
            if type == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                    try visit(url.appendingPathComponent(name), relative: relative.isEmpty ? name : relative + "/" + name)
                }
            }
        }
        _ = try requireEntry(tree, type: S_IFDIR)
        try visit(tree, relative: "")
    }

    private func requireHex(_ value: String, length: Int) throws {
        guard Self.isHex(value, length: length) else {
            throw VPhoneBundleStoreError("Invalid \(length)-digit hexadecimal digest.")
        }
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func failure(_ operation: String, _ url: URL) -> VPhoneBundleStoreError {
        VPhoneBundleStoreError("Unable to \(operation) at \(url.path): \(String(cString: strerror(errno)))")
    }
}

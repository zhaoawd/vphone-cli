import Darwin
import Foundation
import CryptoKit

/// A verified exchange retains the original until both files are rechecked.
/// Recovery completes or aborts only this journal, never a firmware/CFW journal.
enum VPhoneDiskRebaseTransaction {
    static let journalName = "RebaseJournal.json"
    static let historyName = ".disk-rebase-history"

    struct Identity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64

        init(_ url: URL) throws {
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
                throw VPhoneDiskRebaseError.failed(path: url.path, reason: "Expected a private regular file")
            }
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
        }
    }

    struct Journal: Codable {
        let version: Int
        let disk: String
        let original: Identity
        let candidate: Identity
        let sha256: String
        let report: VPhoneDiskRebaseReport
        var status: String
    }

    static func pending(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(VPhoneDiskRebase.stagingPrefix) }
            .filter { url in
                var info = stat()
                return lstat(url.appendingPathComponent(journalName).path, &info) == 0
            }.sorted { $0.path < $1.path }
    }

    static func digest(_ url: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let before = try VPhoneTransferSource.file(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            if isCancelled() { throw CancellationError() }
            guard let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty else { return false }
            hash.update(data: bytes)
            return true
        }) {}
        guard try VPhoneTransferSource.file(url) == before else {
            throw VPhoneDiskRebaseError.failed(path: url.path, reason: "File changed during digest")
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func write(_ record: Journal, in staging: URL) throws {
        let path = staging.appendingPathComponent(journalName)
        let data = try JSONEncoder().encode(record)
        try data.write(to: path, options: .atomic)
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        try file.synchronize()
        try syncDirectory(staging)
    }

    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func publish(target: VPhoneBundle, staged: URL, report: VPhoneDiskRebaseReport,
                        isCancelled: () -> Bool, recheck: () throws -> Void, afterSwap: () throws -> Void) throws {
        let disk = target.url.appendingPathComponent(target.manifest.diskImage)
        let state = try VPhoneTransferSource.file(disk)
        let candidateState = try VPhoneTransferSource.file(staged)
        let expected = try digest(disk, isCancelled: isCancelled)
        guard try digest(staged, isCancelled: isCancelled) == expected,
              try VPhoneTransferSource.file(disk) == state,
              try VPhoneTransferSource.file(staged) == candidateState else {
            throw VPhoneDiskRebaseError.changedDuringRebase(machine: target.name)
        }
        let record = Journal(version: 1, disk: target.manifest.diskImage,
            original: try Identity(disk), candidate: try Identity(staged), sha256: expected,
            report: report, status: "verified")
        try write(record, in: staged.deletingLastPathComponent())
        if isCancelled() { throw CancellationError() }
        try recheck()
        guard renamex_np(staged.path, disk.path, UInt32(RENAME_SWAP)) == 0 else {
            throw VPhoneDiskRebaseError.failed(path: disk.path, reason: String(cString: strerror(errno)))
        }
        try syncDirectory(target.url)
        try afterSwap()
        try finish(target: target, staging: staged.deletingLastPathComponent())
    }

    static func finish(target: VPhoneBundle, staging: URL) throws {
        let journalURL = staging.appendingPathComponent(journalName)
        let revision = try VPhoneTransferSource.file(journalURL)
        let identity = try Identity(journalURL)
        guard identity.size <= 1 << 20 else { throw VPhoneDiskRebaseError.failed(path: journalURL.path, reason: "Oversized journal") }
        let fd = open(journalURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        let data = try input.read(upToCount: (1 << 20) + 1) ?? Data()
        try input.close()
        guard data.count <= 1 << 20, try Identity(journalURL) == identity,
              try VPhoneTransferSource.file(journalURL) == revision else {
            throw VPhoneDiskRebaseError.failed(path: journalURL.path, reason: "Rebase journal changed during read")
        }
        var record = try JSONDecoder().decode(Journal.self, from: data)
        guard record.version == 1, record.disk == target.manifest.diskImage,
              VPhoneVirtualMachineManifest.isPlainFileName(record.disk),
              ["verified", "published", "aborted"].contains(record.status),
              record.sha256.count == 64 else {
            throw VPhoneDiskRebaseError.failed(path: journalURL.path, reason: "Invalid rebase journal")
        }
        let disk = target.url.appendingPathComponent(record.disk)
        let other = staging.appendingPathComponent(record.disk)
        let current = try Identity(disk)
        let published = current == record.candidate
        guard published || current == record.original,
              try digest(disk) == record.sha256 else {
            throw VPhoneDiskRebaseError.failed(path: disk.path, reason: "Rebase recovery cannot verify the current disk")
        }
        if FileManager.default.fileExists(atPath: other.path) {
            guard try Identity(other) == (published ? record.original : record.candidate),
                  try digest(other) == record.sha256 else {
                throw VPhoneDiskRebaseError.failed(path: other.path, reason: "Rebase recovery cannot verify the retained disk")
            }
            record.status = published ? "published" : "aborted"
            try write(record, in: staging)
            guard unlink(other.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try syncDirectory(staging)
        } else {
            guard record.status == (published ? "published" : "aborted") else {
                throw VPhoneDiskRebaseError.failed(path: other.path, reason: "Missing retained rebase image")
            }
        }
        let history = target.url.appendingPathComponent(historyName)
        var info = stat()
        if lstat(history.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw VPhoneDiskRebaseError.failed(path: history.path, reason: "Invalid rebase history directory")
            }
        } else {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let archive = history.appendingPathComponent(staging.lastPathComponent)
        guard renamex_np(staging.path, archive.path, UInt32(RENAME_EXCL)) == 0 else {
            throw VPhoneDiskRebaseError.failed(path: archive.path, reason: String(cString: strerror(errno)))
        }
        try syncDirectory(history)
        try syncDirectory(target.url)
    }
}

extension VPhoneDiskRebase {
    /// Finish a verified pending exchange without rerunning block reconstruction.
    public static func recover(_ target: VPhoneBundle) throws {
        try VPhoneBundleGuard.withBundleLock(directory: target.url, operation: VPhoneVMOperation.rebaseRecover) { _ in
            try VPhoneBundleActivity.requireStopped(target)
            for staging in try VPhoneDiskRebaseTransaction.pending(in: target.url) {
                var info = stat()
                guard lstat(staging.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                    throw VPhoneDiskRebaseError.failed(path: staging.path, reason: "Invalid rebase transaction directory")
                }
                try VPhoneDiskRebaseTransaction.finish(target: target, staging: staging)
            }
        }
    }
}

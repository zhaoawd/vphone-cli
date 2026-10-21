import Darwin
import Foundation

/// Detect source metadata/identity or membership drift before publishing a transfer.
/// Bundle locks exclude cooperating writers. This check also catches ordinary
/// external writes; it is not an atomic filesystem snapshot or a content proof.
enum VPhoneTransferSource {
    static func file(_ url: URL, followLinks: Bool = false) throws -> String {
        var info = stat()
        let result = followLinks ? stat(url.path, &info) : lstat(url.path, &info)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let target = !followLinks && info.st_mode & S_IFMT == S_IFLNK
            ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : ""
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_uid):\(info.st_gid):\(info.st_nlink):\(info.st_size):\(info.st_flags):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(target)"
    }

    static func tree(_ root: URL, excluding patterns: [String], isCancelled: (() -> Bool)?) throws -> [String: String] {
        var members: [String: String] = [:]
        func visit(_ url: URL, relative: String, depth: Int) throws {
            if isCancelled?() == true { throw CancellationError() }
            guard depth <= 128 else { throw VPhoneBundleOpsError.badArchive("VM directory nesting exceeds 128") }
            if !relative.isEmpty, patterns.contains(where: {
                fnmatch($0, relative, 0) == 0 || fnmatch($0, url.lastPathComponent, 0) == 0
            }) { return }
            let before = try file(url)
            members[relative] = before
            if VPhoneNativeTransfer.fileType(at: url) == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                    try visit(url.appendingPathComponent(name), relative: relative.isEmpty ? name : relative + "/" + name, depth: depth + 1)
                }
            }
            guard try file(url) == before else { throw VPhoneBundleOpsError.badArchive("transfer source changed: \(relative)") }
        }
        try visit(root, relative: "", depth: 0)
        return members
    }
}

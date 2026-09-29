import ArchiveKit
import Foundation

/// Reading an archive without unpacking it.
///
/// Listing members and pulling a single one out — reading a BuildManifest from
/// an IPSW without writing 15 GB to disk first.
public enum VPhoneArchiveReader {
    private static let blockSize = 10240

    public struct Entry: Sendable, Equatable {
        public let path: String
        public let size: Int64
        public let isDirectory: Bool
        public let isSymlink: Bool
        public let mode: mode_t
        public let uid: Int
        public let gid: Int
        public let modified: Date?
        /// Where a symlink points, unresolved.
        public let linkTarget: String?
        public let fileType: mode_t
        public let hardlinkTarget: String?
    }

    /// Every member, in the order the archive stores them.
    public static func entries(of archive: URL) throws -> [Entry] {
        try entries(of: archive, maximumEntries: nil)
    }

    public static func entries(of archive: URL, maximumEntries: Int?) throws -> [Entry] {
        try withReader(archive) { reader in
            var found: [Entry] = []
            while let entry = try nextHeader(reader, archive: archive) {
                if let maximumEntries, found.count >= maximumEntries {
                    throw VPhoneArchiveError.readFailed(path: archive.path, reason: "archive entry limit exceeded")
                }
                found.append(makeEntry(entry))
                archive_read_data_skip(reader)
            }
            return found
        }
    }

    /// One member's contents.
    ///
    /// Reads sequentially, so it costs whatever it costs to reach the member.
    /// For a zip on a real file libarchive uses the central directory and the
    /// seek is cheap; for a compressed tar it is not, and the whole stream up
    /// to that point has to be decompressed.
    public static func readMember(_ member: String, from archive: URL, maximumBytes: Int? = nil) throws -> Data {
        try readMember(member, from: archive, maximumBytes: maximumBytes, visited: [])
    }

    private static func readMember(_ member: String, from archive: URL, maximumBytes: Int?, visited: Set<String>) throws -> Data {
        guard !visited.contains(member), visited.count < 64 else {
            throw VPhoneArchiveError.readFailed(path: archive.path, reason: "cyclic or excessively deep hardlink: \(member)")
        }
        var visited = visited
        visited.insert(member)
        return try withReader(archive) { reader in
            while let entry = try nextHeader(reader, archive: archive) {
                let path = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
                guard path == member else {
                    archive_read_data_skip(reader)
                    continue
                }

                if let target = archive_entry_hardlink(entry) {
                    return try readMember(String(cString: target), from: archive, maximumBytes: maximumBytes, visited: visited)
                }

                var data = Data()
                let hint = archive_entry_size(entry)
                if let maximumBytes, hint > maximumBytes || maximumBytes < 0 {
                    throw VPhoneArchiveError.readFailed(path: archive.path, reason: "member exceeds size limit: \(member)")
                }
                if hint > 0 {
                    // Archive metadata is untrusted; grow only as data is actually read.
                    data.reserveCapacity(Int(min(hint, 1 << 20)))
                }

                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let read = buffer.withUnsafeMutableBytes {
                        archive_read_data(reader, $0.baseAddress, $0.count)
                    }
                    if read == 0 {
                        break
                    }
                    guard read > 0 else {
                        throw VPhoneArchiveError.readFailed(
                            path: archive.path,
                            reason: archiveErrorString(reader),
                        )
                    }
                    if let maximumBytes, read > maximumBytes - data.count {
                        throw VPhoneArchiveError.readFailed(path: archive.path, reason: "member exceeds size limit: \(member)")
                    }
                    data.append(contentsOf: buffer[0 ..< Int(read)])
                }
                return data
            }
            throw VPhoneArchiveError.memberNotFound(member: member, archive: archive.path)
        }
    }

    /// The compressor and format libarchive detects, for reporting.
    public static func describe(_ archive: URL) throws -> (format: String, filter: String) {
        try withReader(archive) { reader in
            _ = try nextHeader(reader, archive: archive)
            let format = archive_format_name(reader).map { String(cString: $0) } ?? "unknown"
            let filter = archive_filter_name(reader, 0).map { String(cString: $0) } ?? "none"
            return (format, filter)
        }
    }

    // MARK: - Plumbing

    private static func withReader<T>(
        _ archive: URL,
        _ body: (OpaquePointer?) throws -> T,
    ) throws -> T {
        let reader = archive_read_new()
        archive_read_support_format_all(reader)
        archive_read_support_format_raw(reader)
        archive_read_support_filter_all(reader)
        defer { archive_read_free(reader) }

        guard archive_read_open_filename(reader, archive.path, blockSize) == ARCHIVE_OK else {
            throw VPhoneArchiveError.cannotOpen(
                path: archive.path,
                reason: archiveErrorString(reader),
            )
        }
        return try body(reader)
    }

    private static func nextHeader(
        _ reader: OpaquePointer?,
        archive: URL,
    ) throws -> OpaquePointer? {
        var entry: OpaquePointer?
        let status = archive_read_next_header(reader, &entry)
        if status == ARCHIVE_EOF {
            return nil
        }
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
            throw VPhoneArchiveError.readFailed(
                path: archive.path,
                reason: archiveErrorString(reader),
            )
        }
        return entry
    }

    private static func makeEntry(_ entry: OpaquePointer) -> Entry {
        let fileType = mode_t(archive_entry_filetype(entry))
        let mtime = archive_entry_mtime_is_set(entry) != 0
            ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry)))
            : nil
        return Entry(
            path: archive_entry_pathname(entry).map { String(cString: $0) } ?? "",
            size: archive_entry_size(entry),
            isDirectory: fileType == S_IFDIR,
            isSymlink: fileType == S_IFLNK,
            mode: mode_t(archive_entry_perm(entry)),
            uid: Int(archive_entry_uid(entry)),
            gid: Int(archive_entry_gid(entry)),
            modified: mtime,
            linkTarget: archive_entry_symlink(entry).map { String(cString: $0) },
            fileType: fileType,
            hardlinkTarget: archive_entry_hardlink(entry).map { String(cString: $0) },
        )
    }
}

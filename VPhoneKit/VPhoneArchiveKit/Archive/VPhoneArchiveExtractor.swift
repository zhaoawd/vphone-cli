import ArchiveKit
import Foundation

/// Unpacks an archive onto disk.
///
/// The format and the compressor are detected, so there is no `--zstd` to
/// pass and no way to get it wrong. What the caller does choose is where the
/// files end up belonging, which is the part that differs between unpacking
/// onto a mounted guest volume and unpacking into a scratch directory.
public enum VPhoneArchiveExtractor {
    /// Bytes handed to libarchive per read. 10 KiB is libarchive's own
    /// suggestion and there is no reason here to argue with it.
    private static let blockSize = 10240

    public struct Progress: Sendable {
        public let entriesWritten: Int
        public let bytesWritten: Int64
        public let currentPath: String
    }

    /// Unpack `archive` into `destination`.
    ///
    /// `bytesRead` reports how far into the archive *file* the read has got —
    /// compressed bytes, so it can be shown against the file's size on disk.
    /// It fires per data block, not per entry, because a VM bundle's `Disk.img`
    /// is one entry of many gigabytes.
    ///
    /// - Returns: the number of entries written, not counting any skipped by
    ///   `noOverwriteDir`.
    @discardableResult
    public static func extract(
        _ archive: URL,
        into destination: URL,
        options: VPhoneArchiveExtractOptions,
        progress: ((Progress) -> Void)? = nil,
        bytesRead: ((Int64) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil,
    ) throws -> Int {
        try withArchiveLocale {
            try unpack(
                archive,
                into: destination,
                options: options,
                progress: progress,
                bytesRead: bytesRead,
                isCancelled: isCancelled,
            )
        }
    }

    private static func unpack(
        _ archive: URL,
        into destination: URL,
        options: VPhoneArchiveExtractOptions,
        progress: ((Progress) -> Void)?,
        bytesRead: ((Int64) -> Void)?,
        isCancelled: (() -> Bool)?,
    ) throws -> Int {
        let reader = archive_read_new()
        archive_read_support_format_all(reader)
        archive_read_support_filter_all(reader)
        defer { archive_read_free(reader) }

        let writer = archive_write_disk_new()
        archive_write_disk_set_options(writer, options.extractFlags)
        // Deliberately NOT archive_write_disk_set_standard_lookup(): see
        // VPhoneArchiveOwnership.preserveNumeric. Without it libarchive uses
        // the numeric ids straight from the archive, which is what we want.
        defer { archive_write_free(writer) }

        guard archive_read_open_filename(reader, archive.path, blockSize) == ARCHIVE_OK else {
            throw VPhoneArchiveError.cannotOpen(
                path: archive.path,
                reason: archiveErrorString(reader),
            )
        }

        // Resolved once, and every target is built from the resolved form.
        //
        // Not a tidy-up: ARCHIVE_EXTRACT_SECURE_SYMLINKS checks every
        // component of the path it is given, and on macOS /tmp and /var are
        // themselves symlinks into /private. Handing it an unresolved
        // /var/folders/... target makes it refuse the extraction outright,
        // with "Cannot extract through symlink /var/...". Resolving the
        // destination leaves only components *below* it for the flag to judge,
        // which is the part we actually want judged.
        let resolvedDestination = try VPhoneArchivePaths.resolved(destination)
        let destinationPath = resolvedDestination.path
        var written = 0
        var bytes: Int64 = 0

        while true {
            if isCancelled?() == true {
                throw VPhoneArchiveError.cancelled
            }

            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF {
                break
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else {
                throw VPhoneArchiveError.readFailed(
                    path: archive.path,
                    reason: archiveErrorString(reader),
                )
            }

            // A name libarchive could not convert comes back NULL. Treated as
            // "", it would resolve to the destination itself and pass the
            // containment check below.
            guard let rawPath = archive_entry_pathname(entry) else {
                throw VPhoneArchiveError.readFailed(
                    path: archive.path,
                    reason: archiveErrorString(reader),
                )
            }
            let memberPath = String(cString: rawPath)
            let target = resolvedDestination.appendingPathComponent(memberPath)

            // libarchive's SECURE_* flags already refuse absolute paths and
            // `..`, but they refuse them inside libarchive. Checking the
            // normalised result here as well means the answer does not rest on
            // one flag being set, and the error can name the member.
            // .standardized, not .standardizedFileURL: the latter resolves
            // symlinks as well, and on macOS that turns the /private/var we
            // just resolved back into /var, so the prefix comparison fails
            // against a destination that is perfectly fine. Collapsing "." and
            // ".." is all that is wanted here — the destination was already
            // resolved once, above.
            let targetPath = target.standardized.path
            guard targetPath == destinationPath || targetPath.hasPrefix(destinationPath + "/") else {
                throw VPhoneArchiveError.pathEscapesDestination(
                    member: memberPath,
                    destination: destinationPath,
                )
            }
            archive_entry_set_pathname(entry, targetPath)

            // A hardlink entry names its target as an archive-relative path,
            // and libarchive resolves that against the process's working
            // directory. Since the entry's own path has just been made
            // absolute, the target has to be too, or extraction fails with
            // "Hard-link target 'x' does not exist" — which is what happened.
            //
            // Symlinks are deliberately left alone: their target is data,
            // stored and restored verbatim, and rewriting one would change
            // what the link says.
            if let rawLink = archive_entry_hardlink(entry) {
                let linkPath = String(cString: rawLink)
                let linkTarget = resolvedDestination.appendingPathComponent(linkPath)
                let resolvedLink = linkTarget.standardized.path
                guard resolvedLink.hasPrefix(destinationPath + "/") else {
                    throw VPhoneArchiveError.pathEscapesDestination(
                        member: linkPath,
                        destination: destinationPath,
                    )
                }
                archive_entry_set_hardlink(entry, resolvedLink)
            }

            if options.noOverwriteDir, shouldSkipExistingDirectory(entry, at: target) {
                // Skip the header only. Everything under this directory that
                // does not yet exist is still written on its own entry, which
                // is what GNU tar does too.
                continue
            }

            guard archive_write_header(writer, entry) == ARCHIVE_OK else {
                throw VPhoneArchiveError.writeFailed(
                    path: target.path,
                    reason: archiveErrorString(writer),
                )
            }

            let logicalSize = archive_entry_size(entry)
            var sparseRanges = options.sparseFiles && logicalSize > 0
                && mode_t(archive_entry_filetype(entry)) == S_IFREG
                && archive_entry_hardlink(entry) == nil ? SparseRanges() : nil
            if logicalSize > 0 {
                bytes += try copyData(
                    from: reader,
                    to: writer,
                    sparseRanges: &sparseRanges,
                    logicalSize: logicalSize,
                    isCancelled: isCancelled,
                    onBlock: bytesRead.map { report in
                        { report(archive_filter_bytes(reader, -1)) }
                    },
                )
            }

            if var sparseRanges {
                try sparseRanges.finish(
                    at: target, size: logicalSize, writer: writer,
                    flags: options.extractFlags, isCancelled: isCancelled,
                )
            }
            guard archive_write_finish_entry(writer) == ARCHIVE_OK else {
                throw VPhoneArchiveError.writeFailed(
                    path: target.path,
                    reason: archiveErrorString(writer),
                )
            }

            written += 1
            progress?(Progress(entriesWritten: written, bytesWritten: bytes, currentPath: memberPath))
            // filter -1 is the bottom filter, the archive file itself, so this
            // is the compressed position. Entries with no data never reach the
            // per-block report above, and small ones are most of a bundle.
            bytesRead?(archive_filter_bytes(reader, -1))
        }

        return written
    }

    // MARK: - --no-overwrite-dir

    /// Whether this entry is a directory that already exists and should be
    /// left exactly as it is.
    ///
    /// GNU tar's `--no-overwrite-dir` has no libarchive equivalent, and
    /// neither of the two things libarchive does offer is the same:
    ///
    /// - The default, per `man 3 archive_write_disk`, is that "existing
    ///   directories will have their permissions updated". That is precisely
    ///   what must not happen. `iosbinpack64.tar` carries entries for `usr/`,
    ///   `usr/local/` and `System/`, and unpacking it onto an installed iOS
    ///   volume would stamp the archive's modes and owners over the real
    ///   ones.
    ///
    /// - `ARCHIVE_EXTRACT_NO_OVERWRITE` is too broad in the other direction:
    ///   it skips any existing object of any type, so an ordinary file that
    ///   should be replaced silently is not. libarchive decides per entry, so
    ///   skipping a directory does not affect new files beneath it — the
    ///   problem is only what it does to regular files.
    ///
    /// So: look for a directory entry whose target already exists as a
    /// directory, and skip writing its header. The path is left in place; only
    /// its metadata is left alone.
    private static func shouldSkipExistingDirectory(
        _ entry: OpaquePointer,
        at target: URL,
    ) -> Bool {
        // S_IFDIR rather than AE_IFDIR: the AE_* names are C macros that Swift
        // does not import, and they are defined to the same values as the
        // S_IF* ones precisely so they can be compared like this.
        guard mode_t(archive_entry_filetype(entry)) == S_IFDIR else { return false }

        var info = stat()
        // lstat, not stat: a symlink that points at a directory is a symlink,
        // and replacing it is a different decision from updating a directory.
        guard lstat(target.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: - Data

    private static func copyData(
        from reader: OpaquePointer?,
        to writer: OpaquePointer?,
        sparseRanges: inout SparseRanges?,
        logicalSize: Int64,
        isCancelled: (() -> Bool)?,
        onBlock: (() -> Void)? = nil,
    ) throws -> Int64 {
        var total: Int64 = 0
        while true {
            // Cancellation is checked per block, not per entry: a single
            // multi-gigabyte disk image is one entry, and a check that only
            // happens between entries would not interrupt it.
            if isCancelled?() == true {
                throw VPhoneArchiveError.cancelled
            }

            var buffer: UnsafeRawPointer?
            var size = 0
            var offset: la_int64_t = 0

            let status = archive_read_data_block(reader, &buffer, &size, &offset)
            if status == ARCHIVE_EOF {
                return total
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
                throw VPhoneArchiveError.readFailed(
                    path: "<member data>",
                    reason: archiveErrorString(reader),
                )
            }

            if let buffer {
                sparseRanges?.observe(buffer, count: size, offset: offset, logicalSize: logicalSize)
            }

            guard archive_write_data_block(writer, buffer, size, offset) >= ARCHIVE_OK else {
                throw VPhoneArchiveError.writeFailed(
                    path: "<member data>",
                    reason: archiveErrorString(writer),
                )
            }
            total += Int64(size)
            onBlock?()
        }
    }

    /// Tracks verified zero ranges in the decompressed stream, without a
    /// second read of a VM disk. GNU tar exports may have no sparse map.
    private struct SparseRanges {
        static let zeros = Data(count: 65_536)
        var ranges: [Range<Int64>] = []
        var end: Int64 = 0
        var finalByte: UInt8 = 0
        var valid = true

        mutating func append(_ range: Range<Int64>) {
            guard !range.isEmpty else { return }
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound ..< range.upperBound
            } else {
                ranges.append(range)
            }
        }

        mutating func observe(_ buffer: UnsafeRawPointer, count: Int, offset: Int64, logicalSize: Int64) {
            guard valid, offset >= end, offset <= logicalSize, Int64(count) <= logicalSize - offset else {
                valid = false
                ranges.removeAll()
                return
            }
            append(end ..< offset) // A sparse archive can omit these bytes.
            for cursor in stride(from: 0, to: count, by: Self.zeros.count) {
                let length = min(Self.zeros.count, count - cursor)
                let isZero = Self.zeros.withUnsafeBytes { memcmp(buffer + cursor, $0.baseAddress!, length) == 0 }
                if isZero { append((offset + Int64(cursor)) ..< (offset + Int64(cursor + length))) }
            }
            end = offset + Int64(count)
            if end == logicalSize, count > 0 { finalByte = buffer.load(fromByteOffset: count - 1, as: UInt8.self) }
        }

        mutating func finish(
            at target: URL, size: Int64, writer: OpaquePointer?, flags: Int32,
            isCancelled: (() -> Bool)?,
        ) throws {
            guard valid else { return }
            append(end ..< size)
            guard !ranges.isEmpty else { return }
            // Finish the logical length through libarchive's own descriptor.
            // Its normal final ftruncate/close materializes skipped zero
            // ranges on the measured APFS host. A real final-byte write makes
            // finish_entry skip that sizing path. The byte is unchanged.
            archive_write_disk_set_options(writer, flags & ~Int32(ARCHIVE_EXTRACT_SPARSE))
            let written = withUnsafePointer(to: &finalByte) { archive_write_data_block(writer, $0, 1, size - 1) }
            archive_write_disk_set_options(writer, flags)
            guard written >= ARCHIVE_OK else {
                throw VPhoneArchiveError.writeFailed(path: target.path, reason: archiveErrorString(writer))
            }
            let descriptor = open(target.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            // Sparse allocation is an optimization: an entry whose temporary
            // mode forbids reopening can still be extracted by libarchive.
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
            let block = Int64(max(4096, Int(getpagesize())))
            for range in ranges {
                if isCancelled?() == true { throw VPhoneArchiveError.cancelled }
                let remainder = range.lowerBound % block
                let advance = remainder == 0 ? 0 : block - remainder
                guard range.upperBound - range.lowerBound >= advance else { continue }
                let start = range.lowerBound + advance
                let end = (range.upperBound / block) * block
                guard end > start else { continue }
                var hole = fpunchhole_t()
                hole.fp_offset = off_t(start)
                hole.fp_length = off_t(end - start)
                if fcntl(descriptor, F_PUNCHHOLE, &hole) != 0 {
                    if errno == ENOTSUP || errno == EINVAL { return }
                    throw VPhoneArchiveError.writeFailed(path: target.path, reason: String(cString: strerror(errno)))
                }
            }
            // finish_entry restores timestamps and modes after punching.
        }
    }
}

import CryptoKit
import Darwin
import Foundation
import VPhoneCore
import VPhoneKernelIOTrace

/// In-place disk publication preserves the generation's inode. Every write has
/// a durable cursor. Recovery admits only the exact old/new state or one prefix
/// produced by the one pending pwrite, never arbitrary bytes at that offset.
struct FirmwareKernelDisk: Codable, Equatable {
    enum Direction: String, Codable { case forward, reverse }
    let identity: VPhoneFirmwareIdentity
    let originalSHA256: String
    let candidateSHA256: String
    let size: UInt64
    let offsets: [UInt64]
    var cursor = 0
    var pending = false
    var direction = Direction.forward
    var interruptedSHA256: String?
    var interruptedIndex: Int?
    static let blockSize = 4096
    static let originalName = "kernel-disk-original.img"
    static let candidateName = "kernel-disk-candidate.img"
    static let interruptedName = "kernel-disk-interrupted.bin"

    static func capture(directory: URL, root: URL, candidate: URL,
                        reader: FirmwareKernelDiskBatchReader.Read = FirmwareKernelDiskBatchReader.systemRead) throws -> Self {
        return try KernelIOTrace.measure("kernelDisk.capture") { _ in
            let disk = directory.appendingPathComponent("Disk.img")
            let identity = try VPhoneFirmwareIdentity.read(in: directory)
            guard identity.diskName == "Disk.img" else { throw FirmwareGeneration.fail("Kernel update requires Disk.img") }
            let originalSHA = try FirmwareGeneration.fileSHA256(disk)
            let candidateSHA = try FirmwareGeneration.fileSHA256(candidate)
            let old = root.appendingPathComponent(originalName), new = root.appendingPathComponent(candidateName)
            try FileManager.default.copyItem(at: disk, to: old)
            try FileManager.default.copyItem(at: candidate, to: new)
            // Hash the exact comparison bytes after durability, not before sync.
            try sync(old); try sync(new); try sync(root)
            let (a, oldState) = try FirmwareKernelDiskBatchReader.openChecked(old)
            defer { try? a.close() }
            let (b, newState) = try FirmwareKernelDiskBatchReader.openChecked(new)
            defer { try? b.close() }
            var offsets: [UInt64] = [], offset: UInt64 = 0
            try KernelIOTrace.measure("kernelDisk.capture.compare", labels: FirmwareKernelDiskBatchReader.traceLabels) { span in
                var oldReads = FirmwareKernelDiskBatchReader.Counts(), newReads = FirmwareKernelDiskBatchReader.Counts()
                var oldHash = SHA256(), newHash = SHA256()
                var hashedBytes: Int64 = 0
                var shaFinalizations: Int64 = 0
                var blocks: Int64 = 0
                defer {
                    span?.set("old_read_calls", oldReads.calls); span?.set("new_read_calls", newReads.calls)
                    span?.set("old_bytes", oldReads.bytes); span?.set("new_bytes", newReads.bytes)
                    span?.set("blocks", blocks); span?.set("changed_blocks", Int64(offsets.count)); span?.set("logical_bytes", Int64(clamping: offset))
                    span?.set("old_sha_bytes", hashedBytes); span?.set("new_sha_bytes", hashedBytes)
                    span?.set("fused_sha_finalizations", shaFinalizations)
                }
                let length = try FirmwareKernelDiskBatchReader.length(a)
                guard try FirmwareKernelDiskBatchReader.length(b) == length else {
                    throw FirmwareGeneration.fail("Kernel candidate disk size changed")
                }
                while offset < length {
                    try autoreleasepool {
                        try FirmwareGeneration.checkCancellation()
                        let count = Int(min(UInt64(FirmwareKernelDiskBatchReader.batchSize), length - offset))
                        let x = try FirmwareKernelDiskBatchReader.read(a, offset: offset, count: count, counts: &oldReads, using: reader)
                        let y = try FirmwareKernelDiskBatchReader.read(b, offset: offset, count: count, counts: &newReads, using: reader)
                        oldHash.update(data: x); newHash.update(data: y)
                        hashedBytes += Int64(count)
                        for local in stride(from: 0, to: count, by: blockSize) {
                            autoreleasepool {
                                let end = min(local + blockSize, count)
                                let xb = x[(x.startIndex + local)..<(x.startIndex + end)]
                                let yb = y[(y.startIndex + local)..<(y.startIndex + end)]
                                blocks += 1
                                if xb != yb { offsets.append(offset + UInt64(local)) }
                            }
                        }
                        offset += UInt64(count)
                    }
                }
                guard try FirmwareKernelDiskBatchReader.read(a, offset: length, count: 1, allowEOF: true, counts: &oldReads, using: reader).isEmpty,
                      try FirmwareKernelDiskBatchReader.read(b, offset: length, count: 1, allowEOF: true, counts: &newReads, using: reader).isEmpty else {
                    throw FirmwareGeneration.fail("Kernel candidate disk size changed")
                }
                let oldSHA = oldHash.finalize().map { String(format: "%02x", $0) }.joined()
                let newSHA = newHash.finalize().map { String(format: "%02x", $0) }.joined()
                shaFinalizations = 2
                guard oldSHA == originalSHA, newSHA == candidateSHA else {
                    throw FirmwareGeneration.fail("Kernel disk changed during backup")
                }
            }
            guard try FirmwareGeneration.fileSHA256(disk) == originalSHA else { throw FirmwareGeneration.fail("Kernel disk changed during backup") }
            try FirmwareKernelDiskBatchReader.checkUnchanged(a, at: old, before: oldState)
            try FirmwareKernelDiskBatchReader.checkUnchanged(b, at: new, before: newState)
            return Self(identity: identity, originalSHA256: originalSHA, candidateSHA256: candidateSHA, size: offset, offsets: offsets)
        }
    }

    func validate(directory: URL, root: URL,
                  reader: FirmwareKernelDiskBatchReader.Read = FirmwareKernelDiskBatchReader.systemRead) throws {
        try KernelIOTrace.measure("kernelDisk.validate") { _ in
            guard identity == (try VPhoneFirmwareIdentity.read(in: directory)), cursor >= 0, cursor <= offsets.count,
                  offsets == offsets.sorted(), Set(offsets).count == offsets.count,
                  offsets.allSatisfy({ $0 < size && $0 % UInt64(Self.blockSize) == 0 }),
                  !pending || (direction == .forward ? cursor < offsets.count : cursor > 0),
                  try FirmwareGeneration.fileSHA256(root.appendingPathComponent(Self.originalName)) == originalSHA256,
                  try FirmwareGeneration.fileSHA256(root.appendingPathComponent(Self.candidateName)) == candidateSHA256 else {
                throw FirmwareGeneration.fail("Invalid kernel disk recovery relationship")
            }
            if let hash = interruptedSHA256 {
                guard let index = interruptedIndex, offsets.indices.contains(index),
                      try FirmwareGeneration.fileSHA256(root.appendingPathComponent(Self.interruptedName)) == hash else {
                    throw FirmwareGeneration.fail("Invalid interrupted kernel disk block")
                }
            } else if interruptedIndex != nil { throw FirmwareGeneration.fail("Missing interrupted kernel disk block") }
            let disk = try FileHandle(forReadingFrom: directory.appendingPathComponent("Disk.img"))
            let old = try FileHandle(forReadingFrom: root.appendingPathComponent(Self.originalName))
            let new = try FileHandle(forReadingFrom: root.appendingPathComponent(Self.candidateName))
            defer { try? disk.close(); try? old.close(); try? new.close() }
            try KernelIOTrace.measure("kernelDisk.validate.compare", labels: FirmwareKernelDiskBatchReader.traceLabels) { span in
                var oldReads = FirmwareKernelDiskBatchReader.Counts(), newReads = FirmwareKernelDiskBatchReader.Counts()
                var diskReads = FirmwareKernelDiskBatchReader.Counts(), blocks: Int64 = 0
                var logicalBytes: UInt64 = 0
                defer {
                    span?.set("old_read_calls", oldReads.calls); span?.set("new_read_calls", newReads.calls); span?.set("disk_read_calls", diskReads.calls)
                    span?.set("old_bytes", oldReads.bytes); span?.set("new_bytes", newReads.bytes); span?.set("disk_bytes", diskReads.bytes)
                    span?.set("blocks", blocks); span?.set("logical_bytes", Int64(clamping: logicalBytes))
                }
                guard try FirmwareKernelDiskBatchReader.length(old) == size,
                      try FirmwareKernelDiskBatchReader.length(new) == size,
                      try FirmwareKernelDiskBatchReader.length(disk) == size else {
                    throw FirmwareGeneration.fail("Kernel disk length differs")
                }
                var offset: UInt64 = 0, change = 0
                while offset < size {
                    try autoreleasepool {
                        let count = Int(min(UInt64(FirmwareKernelDiskBatchReader.batchSize), size - offset))
                        let x = try FirmwareKernelDiskBatchReader.read(old, offset: offset, count: count, counts: &oldReads, using: reader)
                        let y = try FirmwareKernelDiskBatchReader.read(new, offset: offset, count: count, counts: &newReads, using: reader)
                        let actual = try FirmwareKernelDiskBatchReader.read(disk, offset: offset, count: count, counts: &diskReads, using: reader)
                        for local in stride(from: 0, to: count, by: Self.blockSize) {
                            try autoreleasepool {
                                let end = min(local + Self.blockSize, count), blockOffset = offset + UInt64(local)
                                let xb = x[(x.startIndex + local)..<(x.startIndex + end)]
                                let yb = y[(y.startIndex + local)..<(y.startIndex + end)]
                                let actualBlock = actual[(actual.startIndex + local)..<(actual.startIndex + end)]
                                let changed = change < offsets.count && offsets[change] == blockOffset
                                let completed = changed && change < cursor
                                let interrupted = completed && change == interruptedIndex
                                if changed && pending && change == (direction == .forward ? cursor : cursor - 1) {
                                    // Build from first, draining any interrupted-file temporary
                                    // before allocating the other two <=4 KiB zero-based copies.
                                    let from = try autoreleasepool { () throws -> Data in
                                        if direction == .reverse && interrupted {
                                            return Self.scanBlockCopy(try VPhoneCreateDigest.strictFileData(root.appendingPathComponent(Self.interruptedName), maximumBytes: Self.blockSize))
                                        }
                                        return Self.scanBlockCopy(direction == .forward ? xb : yb)
                                    }
                                    let to = Self.scanBlockCopy(direction == .forward ? yb : xb)
                                    let current = Self.scanBlockCopy(actualBlock)
                                    guard Self.isWritePrefix(current, from: from, to: to) else { throw FirmwareGeneration.fail("Unknown bytes in pending kernel disk write") }
                                } else {
                                    var expected = completed ? yb : xb
                                    if interrupted {
                                        expected = try VPhoneCreateDigest.strictFileData(root.appendingPathComponent(Self.interruptedName), maximumBytes: Self.blockSize)
                                    }
                                    guard actualBlock == expected else { throw FirmwareGeneration.fail("Unknown external kernel disk modification") }
                                }
                                blocks += 1
                                if changed { change += 1 }
                                logicalBytes = blockOffset + UInt64(end - local)
                            }
                        }
                        offset += UInt64(count)
                    }
                }
                guard try FirmwareKernelDiskBatchReader.read(old, offset: size, count: 1, allowEOF: true, counts: &oldReads, using: reader).isEmpty,
                      try FirmwareKernelDiskBatchReader.read(new, offset: size, count: 1, allowEOF: true, counts: &newReads, using: reader).isEmpty,
                      try FirmwareKernelDiskBatchReader.read(disk, offset: size, count: 1, allowEOF: true, counts: &diskReads, using: reader).isEmpty else {
                    throw FirmwareGeneration.fail("Kernel disk grew")
                }
            }
        }
    }

    private static func scanBlockCopy(_ data: Data) -> Data {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return Data() }
            return Data(bytes: base, count: bytes.count)
        }
    }

    /// A short pwrite changes a contiguous prefix; unknown torn sectors refuse.
    static func isWritePrefix(_ actual: Data, from: Data, to: Data) -> Bool {
        guard actual.count == from.count, actual.count == to.count else { return false }
        var suffix = false
        for i in actual.indices {
            if !suffix && actual[i] == to[i] { continue }
            suffix = true
            if actual[i] != from[i] { return false }
        }
        return true
    }

    mutating func reverse(directory: URL, root: URL, save: (Self) throws -> Void,
                          afterWrite: (UInt64) throws -> Void) throws {
        try KernelIOTrace.measure("kernelDisk.reverse", aggregateChildren: true) { _ in
            try validate(directory: directory, root: root)
            if direction == .forward {
                if pending {
                    let block = try Self.readBlock(directory.appendingPathComponent("Disk.img"), offsets[cursor])
                    let file = root.appendingPathComponent(Self.interruptedName)
                    try block.write(to: file, options: .atomic); try Self.sync(file); try Self.sync(root)
                    interruptedSHA256 = VPhoneCreateDigest.sha256(block); interruptedIndex = cursor
                    cursor += 1
                }
                direction = .reverse; pending = false
                try save(self)
            }
            while cursor > 0 {
                try autoreleasepool {
                    let offset = offsets[cursor - 1]
                    let target = directory.appendingPathComponent("Disk.img")
                    let original = try Self.readBlock(root.appendingPathComponent(Self.originalName), offset)
                    let previous = cursor - 1 == interruptedIndex
                        ? try VPhoneCreateDigest.strictFileData(root.appendingPathComponent(Self.interruptedName), maximumBytes: Self.blockSize)
                        : try Self.readBlock(root.appendingPathComponent(Self.candidateName), offset)
                    let actual = try Self.readBlock(target, offset)
                    guard pending ? Self.isWritePrefix(actual, from: previous, to: original) : actual == previous else {
                        throw FirmwareGeneration.fail("Unknown kernel disk bytes before restoration")
                    }
                    pending = true; try save(self)
                    try writeBlock(original, replacing: actual, to: target, offset: offset)
                    try afterWrite(offset)
                    cursor -= 1; pending = false; try save(self)
                }
            }
            guard try FirmwareGeneration.fileSHA256(directory.appendingPathComponent("Disk.img")) == originalSHA256 else {
                throw FirmwareGeneration.fail("Kernel disk restoration readback failed")
            }
        }
    }

    mutating func publish(directory: URL, root: URL, save: (Self) throws -> Void,
                          afterWrite: (UInt64) throws -> Void) throws {
        try KernelIOTrace.measure("kernelDisk.publish", aggregateChildren: true) { _ in
            try validate(directory: directory, root: root)
            guard direction == .forward, !pending else { throw FirmwareGeneration.fail("Pending kernel disk write requires recovery") }
            while cursor < offsets.count {
                try autoreleasepool {
                    pending = true; try save(self)
                    let offset = offsets[cursor]
                    try writeBlock(Self.readBlock(root.appendingPathComponent(Self.candidateName), offset),
                                   replacing: Self.readBlock(root.appendingPathComponent(Self.originalName), offset),
                                   to: directory.appendingPathComponent("Disk.img"), offset: offset)
                    try afterWrite(offset)
                    cursor += 1; pending = false; try save(self)
                }
            }
            guard try FirmwareGeneration.fileSHA256(directory.appendingPathComponent("Disk.img")) == candidateSHA256 else {
                throw FirmwareGeneration.fail("Kernel disk publication readback failed")
            }
        }
    }

    private static func readBlock(_ file: URL, _ offset: UInt64) throws -> Data {
        return try KernelIOTrace.measure("kernelDisk.readBlock", aggregate: true) { _ in
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? h.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw FirmwareGeneration.fail("Kernel disk block source is not a unique regular file")
            }
            try h.seek(toOffset: offset)
            return try h.read(upToCount: blockSize) ?? Data()
        }
    }
    private func writeBlock(_ data: Data, replacing expected: Data, to file: URL, offset: UInt64) throws {
        try KernelIOTrace.measure("kernelDisk.writeBlock", aggregate: true) { _ in
            let fd = open(file.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
            var info = stat(), named = stat()
            guard fstat(fd, &info) == 0, lstat(file.path, &named) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  Int64(info.st_dev) == identity.diskDevice, UInt64(info.st_ino) == identity.diskInode,
                  Int64(info.st_birthtimespec.tv_sec) == identity.diskBirthSeconds,
                  Int64(info.st_birthtimespec.tv_nsec) == identity.diskBirthNanoseconds,
                  info.st_size >= 0, UInt64(info.st_size) == size,
                  named.st_dev == info.st_dev, named.st_ino == info.st_ino else {
                throw FirmwareGeneration.fail("Kernel disk identity changed before write")
            }
            var current = Data(count: expected.count)
            let readCount = current.withUnsafeMutableBytes { pread(fd, $0.baseAddress, expected.count, off_t(offset)) }
            guard readCount == expected.count, current == expected, !data.isEmpty, data.count == expected.count else {
                throw FirmwareGeneration.fail("Kernel disk bytes changed before write")
            }
            let count = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
            guard count == data.count, KernelIOTrace.synchronize(fd, phase: "kernelDisk.fsync") == 0 else { throw POSIXError(.EIO) }
        }
    }
    private static func sync(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
        guard KernelIOTrace.synchronize(fd, phase: "kernelDisk.fsync") == 0 else { throw POSIXError(.EIO) }
    }
}

/// Only owns bounded read buffers. FileHandle callers retain descriptor ownership.
/// A reader invocation is one native pread attempt in production, including errors.
enum FirmwareKernelDiskBatchReader {
    static let batchSize = 1024 * 1024
    static let traceLabels = ["byte_semantics": "native_pread_positive_return_bytes",
                              "read_call_semantics": "native_pread_attempts_including_EINTR_EOF_errors",
                              "scan_batch_bytes": "1048576", "persistent_block_bytes": "4096"]
    struct Result {
        let count: Int
        let error: Int32
    }
    struct Counts {
        var calls: Int64 = 0
        var bytes: Int64 = 0
    }
    typealias Read = (Int32, UnsafeMutableRawPointer, Int, off_t) -> Result

    // The fused scan retains the same regular-file and read-stability checks
    // as fileSHA256, including the named path's association with the open fd.
    static func openChecked(_ url: URL) throws -> (FileHandle, stat) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FirmwareGeneration.fail("Unreadable or linked kernel backup") }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0 else {
            close(fd)
            throw FirmwareGeneration.fail("Invalid kernel backup type")
        }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), before)
    }

    static func checkUnchanged(_ handle: FileHandle, at url: URL, before: stat) throws {
        var after = stat(), named = stat()
        guard fstat(handle.fileDescriptor, &after) == 0, lstat(url.path, &named) == 0,
              after.st_mode & S_IFMT == S_IFREG, after.st_nlink == 1,
              named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
              before.st_dev == named.st_dev, before.st_ino == named.st_ino,
              before.st_size == after.st_size, before.st_size == named.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FirmwareGeneration.fail("Kernel backup changed while scanning")
        }
    }

    static func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, _ offset: off_t) -> Result {
        let result = Darwin.pread(fd, buffer, count, offset)
        let savedErrno = errno
        return Result(count: result, error: result < 0 ? savedErrno : 0)
    }

    static func length(_ handle: FileHandle) throws -> UInt64 {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw FirmwareGeneration.fail("Kernel scan source is not a regular file with a known length")
        }
        return UInt64(info.st_size)
    }

    static func read(_ handle: FileHandle, offset: UInt64, count: Int, allowEOF: Bool = false,
                     counts: inout Counts, using reader: Read = systemRead) throws -> Data {
        guard count >= 0, count <= batchSize else { throw POSIXError(.EINVAL) }
        let maximumOffset = UInt64(off_t.max)
        guard offset <= maximumOffset,
              count == 0 || UInt64(count - 1) <= maximumOffset - offset else { throw POSIXError(.EOVERFLOW) }
        guard count > 0 else { return Data() }
        var data = Data(count: count), received = 0
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            while received < count {
                guard counts.calls < Int64.max else { throw POSIXError(.EOVERFLOW) }
                counts.calls += 1
                let remaining = count - received
                // The whole requested range was checked before any offset conversion.
                let result = reader(handle.fileDescriptor, buffer.baseAddress!.advanced(by: received),
                                    remaining, off_t(offset + UInt64(received)))
                if result.count < 0 {
                    guard result.count == -1 else { throw POSIXError(.EIO) }
                    if result.error == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: result.error) ?? .EIO)
                }
                guard result.count <= remaining else { throw POSIXError(.EIO) }
                // Count positive bytes immediately, even if a later call fails.
                guard counts.bytes <= Int64.max - Int64(result.count) else { throw POSIXError(.EOVERFLOW) }
                counts.bytes += Int64(result.count)
                if result.count == 0 {
                    guard allowEOF else { throw FirmwareGeneration.fail("Kernel disk length differs: early EOF") }
                    break
                }
                received += result.count
            }
        }
        if received < count { data.removeSubrange(received..<count) }
        return data
    }
}

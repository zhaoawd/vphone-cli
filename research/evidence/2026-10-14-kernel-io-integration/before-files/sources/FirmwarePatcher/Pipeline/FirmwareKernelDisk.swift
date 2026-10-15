import Darwin
import Foundation
import VPhoneCore

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

    static func capture(directory: URL, root: URL, candidate: URL) throws -> Self {
        let disk = directory.appendingPathComponent("Disk.img")
        let identity = try VPhoneFirmwareIdentity.read(in: directory)
        guard identity.diskName == "Disk.img" else { throw FirmwareGeneration.fail("Kernel update requires Disk.img") }
        let originalSHA = try FirmwareGeneration.fileSHA256(disk)
        let candidateSHA = try FirmwareGeneration.fileSHA256(candidate)
        let old = root.appendingPathComponent(originalName), new = root.appendingPathComponent(candidateName)
        try FileManager.default.copyItem(at: disk, to: old)
        try FileManager.default.copyItem(at: candidate, to: new)
        let a = try FileHandle(forReadingFrom: old), b = try FileHandle(forReadingFrom: new)
        defer { try? a.close(); try? b.close() }
        var offsets: [UInt64] = [], offset: UInt64 = 0
        // FileHandle reads can retain autoreleased storage until the enclosing
        // pool drains. Bound its lifetime to one block on large disk images.
        while try autoreleasepool(invoking: { () throws -> Bool in
            let x = try a.read(upToCount: blockSize) ?? Data(), y = try b.read(upToCount: blockSize) ?? Data()
            guard x.count == y.count else { throw FirmwareGeneration.fail("Kernel candidate disk size changed") }
            if x.isEmpty { return false }
            if x != y { offsets.append(offset) }
            offset += UInt64(x.count)
            return true
        }) {}
        try sync(old); try sync(new); try sync(root)
        guard try FirmwareGeneration.fileSHA256(disk) == originalSHA,
              try FirmwareGeneration.fileSHA256(old) == originalSHA,
              try FirmwareGeneration.fileSHA256(new) == candidateSHA else { throw FirmwareGeneration.fail("Kernel disk changed during backup") }
        return Self(identity: identity, originalSHA256: originalSHA, candidateSHA256: candidateSHA, size: offset, offsets: offsets)
    }

    func validate(directory: URL, root: URL) throws {
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
        var offset: UInt64 = 0, change = 0
        while offset < size {
            try autoreleasepool {
                let x = try old.read(upToCount: Self.blockSize) ?? Data(), y = try new.read(upToCount: Self.blockSize) ?? Data()
                let actual = try disk.read(upToCount: Self.blockSize) ?? Data()
                guard !x.isEmpty, x.count == y.count, actual.count == x.count else { throw FirmwareGeneration.fail("Kernel disk length differs") }
                let changed = change < offsets.count && offsets[change] == offset
                var expected = changed && change < cursor ? y : x
                if changed && change == interruptedIndex && change < cursor {
                    expected = try VPhoneCreateDigest.strictFileData(root.appendingPathComponent(Self.interruptedName), maximumBytes: Self.blockSize)
                }
                if changed && pending && change == (direction == .forward ? cursor : cursor - 1) {
                    let from = direction == .forward ? x : expected
                    let to = direction == .forward ? y : x
                    guard Self.isWritePrefix(actual, from: from, to: to) else { throw FirmwareGeneration.fail("Unknown bytes in pending kernel disk write") }
                } else if actual != expected { throw FirmwareGeneration.fail("Unknown external kernel disk modification") }
                if changed { change += 1 }
                offset += UInt64(x.count)
            }
        }
        guard (try disk.read(upToCount: 1) ?? Data()).isEmpty else { throw FirmwareGeneration.fail("Kernel disk grew") }
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

    mutating func publish(directory: URL, root: URL, save: (Self) throws -> Void,
                          afterWrite: (UInt64) throws -> Void) throws {
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

    private static func readBlock(_ file: URL, _ offset: UInt64) throws -> Data {
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
    private func writeBlock(_ data: Data, replacing expected: Data, to file: URL, offset: UInt64) throws {
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
        guard count == data.count, fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
    private static func sync(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}

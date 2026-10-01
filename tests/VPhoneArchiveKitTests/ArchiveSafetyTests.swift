import ArchiveKit
import Darwin
import Foundation
import Testing
@testable import VPhoneArchiveKit

@Suite("Archive output and extraction safety", .serialized)
struct ArchiveSafetyTests {
    private func withScratch(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func existingOutputsAndDanglingSymlinksArePreserved() throws {
        try withScratch { (root: URL) throws -> Void in
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let existing = root.appendingPathComponent("existing")
            let sentinel = Data("keep".utf8)
            try sentinel.write(to: existing)
            let symlink = root.appendingPathComponent("symlink")
            try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: "missing")
            for output in [existing, symlink] {
                #expect(throws: (any Error).self) { try VPhoneArchiveWriter.create(archive: output, from: source) }
                #expect(throws: (any Error).self) { try VPhoneArchiveWriter.decompress(existing, to: output) }
            }
            #expect(try Data(contentsOf: existing) == sentinel)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == "missing")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
        }
    }

    @Test func outputInsideSourceAndInvalidTopLevelAreRefused() throws {
        try withScratch { (root: URL) throws -> Void in
            #expect(throws: (any Error).self) {
                try VPhoneArchiveWriter.create(archive: root.appendingPathComponent("self.tar"), from: root)
            }
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            for name in ["", "/absolute", "../outside", "nested/../outside"] {
                #expect(throws: (any Error).self) {
                    try VPhoneArchiveWriter.create(archive: root.appendingPathComponent("out.tar"), from: source, topLevel: name)
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source"])
        }
    }

    @Test func publicationRaceDoesNotReplaceCompetingFile() throws {
        try withScratch { (root: URL) throws -> Void in
            let output = root.appendingPathComponent("result")
            #expect(throws: (any Error).self) {
                try VPhoneArchiveOutput.publish(to: output) { temporary in
                    try Data("ours".utf8).write(to: temporary)
                    try Data("theirs".utf8).write(to: output)
                }
            }
            #expect(try String(contentsOf: output, encoding: .utf8) == "theirs")
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["result"])
        }
    }

    @Test func cancellationWithinOneFileRemovesUnpublishedOutput() throws {
        try withScratch { (root: URL) throws -> Void in
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data(repeating: 0x5a, count: 4 << 20).write(to: source.appendingPathComponent("large"))
            var copied: Int64 = 0
            #expect(throws: (any Error).self) {
                try VPhoneArchiveWriter.create(archive: root.appendingPathComponent("out.tar"), from: source,
                                               bytesPacked: { copied = $0 }, isCancelled: { copied > 0 })
            }
            #expect(copied > 0 && copied < 4 << 20)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source"])
        }
    }

    @Test func failedDecompressionRemovesStaging() throws {
        try withScratch { (root: URL) throws -> Void in
            #expect(throws: (any Error).self) {
                try VPhoneArchiveWriter.decompress(root.appendingPathComponent("missing"), to: root.appendingPathComponent("output"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    // Write member names verbatim, including names a normal tree walk cannot produce.
    private func makeArchive(_ path: URL, members: [(String, String?, String?)]) throws {
        let writer = archive_write_new()
        defer { archive_write_free(writer) }
        #expect(archive_write_set_format_pax_restricted(writer) == ARCHIVE_OK)
        try #require(archive_write_open_filename(writer, path.path) == ARCHIVE_OK)
        for (name, symlink, hardlink) in members {
            let entry = archive_entry_new()
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, name)
            archive_entry_set_filetype(entry, UInt32(symlink == nil ? S_IFREG : S_IFLNK))
            archive_entry_set_perm(entry, 0o600)
            archive_entry_set_size(entry, 0)
            if let symlink { archive_entry_set_symlink(entry, symlink) }
            if let hardlink { archive_entry_set_hardlink(entry, hardlink) }
            try #require(archive_write_header(writer, entry) == ARCHIVE_OK)
            try #require(archive_write_finish_entry(writer) == ARCHIVE_OK)
        }
        try #require(archive_write_close(writer) == ARCHIVE_OK)
    }

    @Test(arguments: ["/absolute", "../outside", "nested/../../outside"])
    func unsafeMemberAndHardlinkPathsAreRejected(path: String) throws {
        try withScratch { (root: URL) throws -> Void in
            let destination = root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for (index, members) in [[(path, nil as String?, nil as String?)], [("link", nil, path)]].enumerated() {
                let archive = root.appendingPathComponent("\(index).tar")
                try makeArchive(archive, members: members)
                #expect(throws: (any Error).self) {
                    try VPhoneArchiveExtractor.extract(archive, into: destination, options: .intoHostDirectory)
                }
                #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            }
        }
    }

    @Test func extractionDoesNotFollowArchiveSymlinkOutsideDestination() throws {
        try withScratch { (root: URL) throws -> Void in
            let destination = root.appendingPathComponent("destination")
            let outside = root.appendingPathComponent("outside")
            for directory in [destination, outside] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            let sentinel = outside.appendingPathComponent("keep")
            try Data("keep".utf8).write(to: sentinel)
            let archive = root.appendingPathComponent("attack.tar")
            try makeArchive(archive, members: [("escape", outside.path, nil), ("escape/keep", nil, nil)])
            #expect(throws: (any Error).self) {
                try VPhoneArchiveExtractor.extract(archive, into: destination, options: .intoHostDirectory)
            }
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        }
    }

    @Test func readingHardlinksReturnsContentAndRejectsCycles() throws {
        try withScratch { (root: URL) throws -> Void in
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let payload = Data([0x00, 0xff, 0x42])
            try payload.write(to: source.appendingPathComponent("first"))
            try FileManager.default.linkItem(at: source.appendingPathComponent("first"), to: source.appendingPathComponent("second"))
            let archive = root.appendingPathComponent("links.tar")
            try VPhoneArchiveWriter.create(archive: archive, from: source)
            for name in ["first", "second"] {
                #expect(try VPhoneArchiveReader.readMember(name, from: archive) == payload)
            }
            let cyclic = root.appendingPathComponent("cycle.tar")
            try makeArchive(cyclic, members: [("a", nil, "b"), ("b", nil, "a")])
            #expect(throws: (any Error).self) { try VPhoneArchiveReader.readMember("a", from: cyclic) }
        }
    }

    @Test func sparseRoundTripPreservesBytesAndLowAllocation() throws {
        try withScratch { (root: URL) throws -> Void in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            for directory in [source, destination] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            let input = source.appendingPathComponent("sparse")
            #expect(FileManager.default.createFile(atPath: input.path, contents: nil))
            let handle = try FileHandle(forWritingTo: input)
            // A 16 MiB fixture retained full allocation on this host, as did the
            // earlier 32 MiB bsdtar fixture. Use the established 256 MiB scale.
            try handle.truncate(atOffset: 256 << 20)
            for offset: UInt64 in [0, 128 << 20, (256 << 20) - 8192] {
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: Data(repeating: 0x42, count: 4096))
            }
            try handle.close()
            let archive = root.appendingPathComponent("sparse.tar")
            try VPhoneArchiveWriter.create(archive: archive, from: source)
            try VPhoneArchiveExtractor.extract(archive, into: destination, options: .intoHostDirectory)
            let output = destination.appendingPathComponent("sparse")
            let before = try FileHandle(forReadingFrom: input)
            let after = try FileHandle(forReadingFrom: output)
            defer { try? before.close(); try? after.close() }
            while try autoreleasepool(invoking: { () throws -> Bool in
                let a = try before.read(upToCount: 1 << 20) ?? Data()
                let b = try after.read(upToCount: 1 << 20) ?? Data()
                #expect(a == b)
                return !a.isEmpty
            }) {}
            var info = stat()
            try #require(lstat(output.path, &info) == 0)
            #expect(info.st_size == 256 << 20)
            #expect(info.st_blocks * 512 < info.st_size / 2)
        }
    }

    /// T03: on a decmpfs (UF_COMPRESSED) file, lseek(SEEK_DATA) and SEEK_HOLE
    /// fail with ENXIO, which a sparse scan reads as "all hole". A VM bundle
    /// holds such a file (AVPSEPBooter.vresearch1.bin). Every archive format
    /// must still carry its bytes, not zeros.
    @Test(arguments: [VPhoneArchiveFormat.gnutar, .pax, .ustar])
    func decmpfsCompressedFileKeepsItsBytes(format: VPhoneArchiveFormat) throws {
        try withScratch { (root: URL) throws -> Void in
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            for directory in [source, destination] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            var content = Data()
            for index in 0 ..< 8 {
                content.append(Data(repeating: UInt8(0x41 + index), count: 4096))
                content.append(Data(repeating: 0, count: 4096))
            }
            let input = source.appendingPathComponent("booter.bin")
            try DecmpfsFixture.write(content, to: input)
            var info = stat()
            try #require(lstat(input.path, &info) == 0)
            try #require(info.st_flags & UInt32(UF_COMPRESSED) != 0, "fixture is not decmpfs-compressed")
            let fd = open(input.path, O_RDONLY)
            try #require(fd >= 0)
            errno = 0
            let data = lseek(fd, 0, SEEK_DATA)
            let seekError = errno
            close(fd)
            // The condition this test exists for (observed on macOS 27).
            #expect(data < 0 && seekError == ENXIO, "fixture no longer reproduces SEEK_DATA ENXIO")

            let archive = root.appendingPathComponent("decmpfs.tar")
            try VPhoneArchiveWriter.create(archive: archive, from: source, format: format)
            #expect(try VPhoneArchiveReader.readMember("booter.bin", from: archive) == content)
            try VPhoneArchiveExtractor.extract(archive, into: destination, options: .intoHostDirectory)
            #expect(try Data(contentsOf: destination.appendingPathComponent("booter.bin")) == content)
        }
    }
}

/// A decmpfs type 3 file (zlib stream in the `com.apple.decmpfs` xattr), made
/// the way afsctool does: empty data fork, xattr, then UF_COMPRESSED.
enum DecmpfsFixture {
    static func write(_ content: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw POSIXError(.EIO)
        }
        var value = Data()
        value.append(contentsOf: [0x66, 0x70, 0x6D, 0x63]) // "fpmc", little-endian 'cmpf'
        var type = UInt32(3).littleEndian
        value.append(Data(bytes: &type, count: 4))
        var size = UInt64(content.count).littleEndian
        value.append(Data(bytes: &size, count: 8))
        value.append(try zlib(content))
        let status = value.withUnsafeBytes { bytes in
            setxattr(url.path, "com.apple.decmpfs", bytes.baseAddress, bytes.count, 0, XATTR_SHOWCOMPRESSION)
        }
        guard status == 0, chflags(url.path, UInt32(UF_COMPRESSED)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// RFC 1950 framing around the raw deflate stream NSData produces.
    private static func zlib(_ content: Data) throws -> Data {
        let deflated = try (content as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in content {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        var checksum = ((b << 16) | a).bigEndian
        return Data([0x78, 0x9C]) + deflated + Data(bytes: &checksum, count: 4)
    }
}

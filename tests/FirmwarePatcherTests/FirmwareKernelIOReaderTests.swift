import Darwin
import Foundation
import Virtualization
import VPhoneCore
import XCTest
@testable import FirmwarePatcher

final class FirmwareKernelIOReaderTests: XCTestCase {
    private typealias Reader = FirmwareKernelDiskBatchReader

    private final class Fixture {
        let directory: URL
        let vm: URL
        let root: URL
        let original: Data
        let candidate: Data
        let initial: FirmwareKernelDisk
        var disk: URL { vm.appendingPathComponent("Disk.img") }
        var input: URL { directory.appendingPathComponent("candidate.img") }
        init(size: Int = 8195) throws {
            directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("vphone-kernel-io-reader-" + UUID().uuidString)
            vm = directory.appendingPathComponent("vm"); root = directory.appendingPathComponent("backup")
            original = Data(repeating: 0x11, count: size)
            var altered = original
            for offset in Set([0, 4096, 1024 * 1024 + 4096, size - 1]) where offset < size {
                let end = min(offset + 4096, size)
                altered.replaceSubrange(offset..<end, with: Data(repeating: 0x99, count: end - offset))
            }
            candidate = altered
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try original.write(to: vm.appendingPathComponent("Disk.img"))
            try candidate.write(to: directory.appendingPathComponent("candidate.img"))
            try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": VZMacMachineIdentifier().dataRepresentation,
                "diskImage": "Disk.img"], format: .binary, options: 0).write(to: vm.appendingPathComponent("config.plist"))
            initial = try FirmwareKernelDisk.capture(directory: vm, root: root, candidate: directory.appendingPathComponent("candidate.img"))
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func captureRoot() throws -> URL {
            let result = directory.appendingPathComponent("capture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
            return result
        }
    }

    private func assertPOSIX(_ code: POSIXErrorCode, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? POSIXError)?.code, code, file: file, line: line)
        }
    }

    func testReaderFillsEveryPositiveShortReadAndPreservesDescriptorPosition() throws {
        let f = try Fixture()
        let handle = try FileHandle(forReadingFrom: f.disk)
        defer { try? handle.close() }
        for limit in [1, 4095, 4096, 4097] {
            try handle.seek(toOffset: 7)
            var counts = Reader.Counts(), positions: [off_t] = []
            let result = try Reader.read(handle, offset: 11, count: 8184, counts: &counts) { fd, buffer, count, offset in
                positions.append(offset)
                return Reader.systemRead(fd, buffer, min(count, limit), offset)
            }
            XCTAssertEqual(result, f.original.subdata(in: 11..<8195))
            XCTAssertEqual(result.startIndex, 0)
            XCTAssertEqual(counts.bytes, 8184)
            XCTAssertEqual(counts.calls, Int64((8184 + limit - 1) / limit))
            XCTAssertEqual(positions, stride(from: off_t(11), to: off_t(8195), by: limit).map { $0 })
            XCTAssertEqual(try handle.offset(), 7)
            XCTAssertEqual(try handle.read(upToCount: 1), Data([0x11]))
        }
    }

    func testActualCaptureAndValidateAcceptShortReadsIncludingBatchTail() throws {
        for limit in [1, 4095, 4096, 4097] {
            let f = try Fixture(size: limit == 1 ? 8195 : 1024 * 1024 + 4097)
            var attempts = 0
            let reader: Reader.Read = { fd, buffer, count, offset in
                attempts += 1
                return Reader.systemRead(fd, buffer, min(count, limit), offset)
            }
            let captured = try FirmwareKernelDisk.capture(directory: f.vm, root: f.captureRoot(), candidate: f.input, reader: reader)
            XCTAssertEqual(captured, f.initial)
            try f.initial.validate(directory: f.vm, root: f.root, reader: reader)
            XCTAssertGreaterThan(attempts, 0)
            XCTAssertEqual(try Data(contentsOf: f.disk), f.original)
        }
    }

    func testEINTRBeforeAndBetweenPartialReadsRetriesWithSameOffset() throws {
        let f = try Fixture(), handle = try FileHandle(forReadingFrom: f.disk)
        defer { try? handle.close() }
        var counts = Reader.Counts(), positions: [off_t] = [], attempt = 0
        let data = try Reader.read(handle, offset: 0, count: 8, counts: &counts) { fd, buffer, count, offset in
            defer { attempt += 1 }; positions.append(offset)
            if attempt == 0 || attempt == 2 { return Reader.Result(count: -1, error: EINTR) }
            return Reader.systemRead(fd, buffer, min(count, 3), offset)
        }
        XCTAssertEqual(data, Data(repeating: 0x11, count: 8))
        XCTAssertEqual(positions, [0, 0, 3, 3, 6]); XCTAssertEqual(counts.calls, 5); XCTAssertEqual(counts.bytes, 8)

        var calls = 0
        let interrupted: Reader.Read = { fd, buffer, count, offset in
            defer { calls += 1 }
            if calls == 0 || calls == 2 { return Reader.Result(count: -1, error: EINTR) }
            return Reader.systemRead(fd, buffer, min(count, 4095), offset)
        }
        let captured = try FirmwareKernelDisk.capture(directory: f.vm, root: f.captureRoot(), candidate: f.input, reader: interrupted)
        XCTAssertEqual(captured, f.initial)
        calls = 0
        try f.initial.validate(directory: f.vm, root: f.root, reader: interrupted)
    }

    func testPositiveBytesRemainCountedWhenLaterErrorOrEarlyEOFFails() throws {
        let f = try Fixture(), handle = try FileHandle(forReadingFrom: f.disk)
        defer { try? handle.close() }
        for earlyEOF in [false, true] {
            var counts = Reader.Counts(), calls = 0
            let reader: Reader.Read = { fd, buffer, count, offset in
                defer { calls += 1 }
                if calls == 0 { return Reader.systemRead(fd, buffer, min(count, 3), offset) }
                return Reader.Result(count: earlyEOF ? 0 : -1, error: earlyEOF ? 0 : EIO)
            }
            XCTAssertThrowsError(try Reader.read(handle, offset: 0, count: 8, counts: &counts, using: reader)) { error in
                if !earlyEOF { XCTAssertEqual((error as? POSIXError)?.code, .EIO) }
            }
            XCTAssertEqual(counts.calls, 2); XCTAssertEqual(counts.bytes, 3)
            XCTAssertGreaterThanOrEqual(fcntl(handle.fileDescriptor, F_GETFD), 0)
            XCTAssertEqual(try Data(contentsOf: f.disk), f.original)
        }
    }

    func testActualHelpersRejectPartialThenErrorAndEarlyEOFWithoutLiveWrites() throws {
        for operation in ["capture", "validate"] {
            for earlyEOF in [false, true] {
                let f = try Fixture()
                var calls = 0, positiveBytes = 0
                let reader: Reader.Read = { fd, buffer, count, offset in
                    defer { calls += 1 }
                    if calls == 0 {
                        let result = Reader.systemRead(fd, buffer, min(count, 3), offset)
                        positiveBytes += max(0, result.count)
                        return result
                    }
                    return Reader.Result(count: earlyEOF ? 0 : -1, error: earlyEOF ? 0 : EIO)
                }
                if operation == "capture" {
                    XCTAssertThrowsError(try FirmwareKernelDisk.capture(directory: f.vm, root: f.captureRoot(), candidate: f.input, reader: reader))
                } else {
                    XCTAssertThrowsError(try f.initial.validate(directory: f.vm, root: f.root, reader: reader))
                }
                XCTAssertEqual(calls, 2); XCTAssertEqual(positiveBytes, 3)
                XCTAssertEqual(try Data(contentsOf: f.disk), f.original)
                // Compare-span deferred counters must also report two attempts/three bytes.
                print("kernel-io-reader-error operation=\(operation) early_eof=\(earlyEOF) old_read_calls=2 old_bytes=3")
            }
        }
    }

    func testEOFProbeAndPartialAllowedEOFCountOnlyPositiveBytes() throws {
        let f = try Fixture(), handle = try FileHandle(forReadingFrom: f.disk)
        defer { try? handle.close() }
        var counts = Reader.Counts()
        let eof = try Reader.read(handle, offset: UInt64(f.original.count), count: 1, allowEOF: true, counts: &counts)
        XCTAssertEqual(eof, Data()); XCTAssertEqual(counts.calls, 1); XCTAssertEqual(counts.bytes, 0)
        counts = Reader.Counts()
        let tail = try Reader.read(handle, offset: UInt64(f.original.count - 2), count: 8, allowEOF: true, counts: &counts)
        XCTAssertEqual(tail, Data(repeating: 0x11, count: 2))
        XCTAssertEqual(counts.calls, 2); XCTAssertEqual(counts.bytes, 2)
        counts = Reader.Counts()
        XCTAssertEqual(try Reader.read(handle, offset: 0, count: 0, counts: &counts), Data())
        XCTAssertEqual(counts.calls, 0); XCTAssertEqual(counts.bytes, 0)
    }

    func testInvalidRequestsOverflowAndMalformedReaderResultsRefuse() throws {
        let f = try Fixture(), handle = try FileHandle(forReadingFrom: f.disk)
        defer { try? handle.close() }
        for (offset, count, code) in [(UInt64.max, 1, POSIXErrorCode.EOVERFLOW),
                                      (UInt64(off_t.max), 2, .EOVERFLOW), (0, -1, .EINVAL), (0, Reader.batchSize + 1, .EINVAL)] {
            var counts = Reader.Counts(), calls = 0
            assertPOSIX(code) {
                _ = try Reader.read(handle, offset: offset, count: count, counts: &counts) { _, _, _, _ in
                    calls += 1; return Reader.Result(count: 0, error: 0)
                }
            }
            XCTAssertEqual(calls, 0); XCTAssertEqual(counts.calls, 0)
        }
        for malformed in [-2, 9] {
            var counts = Reader.Counts()
            assertPOSIX(.EIO) {
                _ = try Reader.read(handle, offset: 0, count: 8, counts: &counts) { _, _, _, _ in Reader.Result(count: malformed, error: 0) }
            }
            XCTAssertEqual(counts.calls, 1); XCTAssertEqual(counts.bytes, 0)
        }
        var counts = Reader.Counts(calls: Int64.max, bytes: 0)
        assertPOSIX(.EOVERFLOW) { _ = try Reader.read(handle, offset: 0, count: 1, counts: &counts) }
        var byteOverflow = Reader.Counts(calls: 0, bytes: Int64.max)
        assertPOSIX(.EOVERFLOW) { _ = try Reader.read(handle, offset: 0, count: 1, counts: &byteOverflow) }
        var storage = UInt8(0)
        let failed = withUnsafeMutablePointer(to: &storage) { pointer in Reader.systemRead(-1, pointer, 1, 0) }
        XCTAssertEqual(failed.count, -1); XCTAssertEqual(failed.error, EBADF)
    }

    func testKnownLengthRejectsWrongStateBeforeReadAndEOFProbeRejectsGrowth() throws {
        let f = try Fixture()
        for wrongSize in [f.initial.size - 1, f.initial.size + 1] {
            let wrong = FirmwareKernelDisk(identity: f.initial.identity, originalSHA256: f.initial.originalSHA256,
                candidateSHA256: f.initial.candidateSHA256, size: wrongSize, offsets: f.initial.offsets)
            var calls = 0
            XCTAssertThrowsError(try wrong.validate(directory: f.vm, root: f.root, reader: { fd, buffer, count, offset in
                calls += 1; return Reader.systemRead(fd, buffer, count, offset)
            }))
            XCTAssertEqual(calls, 0)
        }
        var appended = false
        XCTAssertThrowsError(try f.initial.validate(directory: f.vm, root: f.root, reader: { fd, buffer, count, offset in
            if UInt64(offset) == f.initial.size && !appended {
                do {
                    let writer = try FileHandle(forWritingTo: f.disk)
                    defer { try? writer.close() }
                    _ = try writer.seekToEnd(); try writer.write(contentsOf: Data([0x71]))
                    try writer.close(); appended = true
                } catch {
                    XCTFail("Ordinary-file growth injection failed: \(error)")
                    return Reader.Result(count: -1, error: EIO)
                }
            }
            return Reader.systemRead(fd, buffer, count, offset)
        }))
        XCTAssertTrue(appended)
        XCTAssertEqual(try Data(contentsOf: f.disk), f.original + Data([0x71]))
    }

    func testPendingNonzeroBatchSlicesAndInterruptedReverseBlockUseZeroBasedCopies() throws {
        let f = try Fixture(size: 2 * 1024 * 1024 + 17)
        let index = try XCTUnwrap(f.initial.offsets.firstIndex(of: UInt64(1024 * 1024 + 4096)))
        let start = Int(f.initial.offsets[index]), end = start + 4096
        var live = f.original
        for offset in f.initial.offsets.prefix(index) {
            let lo = Int(offset), hi = min(lo + 4096, live.count)
            live.replaceSubrange(lo..<hi, with: f.candidate[lo..<hi])
        }
        var interrupted = f.original.subdata(in: start..<end)
        interrupted.replaceSubrange(0..<777, with: f.candidate[start..<(start + 777)])
        live.replaceSubrange(start..<end, with: interrupted)
        try live.write(to: f.disk)
        var state = f.initial; state.cursor = index; state.pending = true
        try state.validate(directory: f.vm, root: f.root)

        let saved = f.root.appendingPathComponent(FirmwareKernelDisk.interruptedName)
        try interrupted.write(to: saved)
        live.replaceSubrange(start..<(start + 111), with: f.original[start..<(start + 111)])
        try live.write(to: f.disk)
        state.direction = .reverse; state.cursor = index + 1
        state.interruptedIndex = index; state.interruptedSHA256 = VPhoneCreateDigest.sha256(interrupted)
        try state.validate(directory: f.vm, root: f.root)
        var bad = live; bad[start + 200] = 0x37; try bad.write(to: f.disk)
        XCTAssertThrowsError(try state.validate(directory: f.vm, root: f.root))
        XCTAssertEqual(try Data(contentsOf: f.disk), bad)
    }

    func testArchiveGrowthAtPartialTailIsRejected() throws {
        for name in [FirmwareKernelDisk.originalName, FirmwareKernelDisk.candidateName] {
            let f = try Fixture(size: 1024 * 1024 + 3)
            let archive = f.root.appendingPathComponent(name)
            var named = stat()
            XCTAssertEqual(lstat(archive.path, &named), 0)
            var appended = false
            XCTAssertThrowsError(try f.initial.validate(directory: f.vm, root: f.root, reader: { fd, buffer, count, offset in
                var opened = stat()
                if offset == 1024 * 1024 && fstat(fd, &opened) == 0,
                   opened.st_dev == named.st_dev, opened.st_ino == named.st_ino, !appended {
                    do {
                        let writer = try FileHandle(forWritingTo: archive)
                        defer { try? writer.close() }
                        _ = try writer.seekToEnd(); try writer.write(contentsOf: Data([0x71]))
                        try writer.close(); appended = true
                    } catch {
                        XCTFail("Ordinary archive growth injection failed: \(error)")
                        return Reader.Result(count: -1, error: EIO)
                    }
                }
                return Reader.systemRead(fd, buffer, count, offset)
            }), name)
            XCTAssertTrue(appended, name)
            XCTAssertEqual(try Data(contentsOf: f.disk), f.original)
            XCTAssertEqual(try Data(contentsOf: archive).count, f.original.count + 1)
        }
    }
}

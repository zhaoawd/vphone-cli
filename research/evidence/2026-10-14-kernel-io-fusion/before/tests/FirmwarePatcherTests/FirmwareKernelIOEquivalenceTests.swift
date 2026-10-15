import Darwin
import Foundation
import Virtualization
import VPhoneCore
import XCTest
@testable import FirmwarePatcher

/// Real disk publication/recovery helper, using only independent ordinary files.
final class FirmwareKernelIOEquivalenceTests: XCTestCase {
    private let batch = 1 << 20

    private final class Fixture {
        let directory: URL
        let vm: URL
        let root: URL
        let original: Data
        let candidate: Data
        let initial: FirmwareKernelDisk
        var live: URL { vm.appendingPathComponent("Disk.img") }

        init(original: Data, candidate: Data) throws {
            directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("vphone-kernel-io-equivalence-" + UUID().uuidString)
            vm = directory.appendingPathComponent("vm")
            root = directory.appendingPathComponent("backup")
            self.original = original; self.candidate = candidate
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try original.write(to: vm.appendingPathComponent("Disk.img"))
            try PropertyListSerialization.data(fromPropertyList: [
                "machineIdentifier": VZMacMachineIdentifier().dataRepresentation, "diskImage": "Disk.img",
            ], format: .binary, options: 0).write(to: vm.appendingPathComponent("config.plist"))
            let input = directory.appendingPathComponent("candidate.img")
            try candidate.write(to: input)
            initial = try FirmwareKernelDisk.capture(directory: vm, root: root, candidate: input)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(size: Int) throws -> Fixture {
        var original = Data(count: size)
        original.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for index in 0..<size { bytes[index] = UInt8((index * 37 + index / 4096 * 17 + 11) % 251) }
        }
        var candidate = original
        let positions = [0, 1, 4095, 4096, 4097, batch - 1, batch, batch + 1,
                         2 * batch - 1, 2 * batch, 2 * batch + 1, size - 1]
        for position in Set(positions) where position >= 0 && position < size { candidate[position] ^= 0xff }
        return try Fixture(original: original, candidate: candidate)
    }

    private func expectedOffsets(_ original: Data, _ candidate: Data) -> [UInt64] {
        stride(from: 0, to: original.count, by: 4096).compactMap { start in
            let end = min(start + 4096, original.count)
            return original[start..<end] == candidate[start..<end] ? nil : UInt64(start)
        }
    }

    private func bytes(_ f: Fixture, cursor: Int) -> Data {
        var result = f.original
        for offset in f.initial.offsets.prefix(cursor) {
            let start = Int(offset), end = min(start + 4096, result.count)
            result.replaceSubrange(start..<end, with: f.candidate[start..<end])
        }
        return result
    }

    func testCaptureOffsetsAndRoundTripAcrossReadBatchBoundaries() throws {
        for size in [0, 1, 4095, 4096, 4097, batch - 1, batch, batch + 1, 2 * batch + 8195] {
            let f = try fixture(size: size)
            XCTAssertEqual(f.initial.size, UInt64(size))
            XCTAssertEqual(f.initial.offsets, expectedOffsets(f.original, f.candidate), "size=\(size)")
            XCTAssertEqual(f.initial.originalSHA256, VPhoneCreateDigest.sha256(f.original))
            XCTAssertEqual(f.initial.candidateSHA256, VPhoneCreateDigest.sha256(f.candidate))
            var state = f.initial
            try state.validate(directory: f.vm, root: f.root)
            var writes: [UInt64] = []
            try state.publish(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { writes.append($0) })
            XCTAssertEqual(writes, f.initial.offsets)
            XCTAssertEqual(try Data(contentsOf: f.live), f.candidate)
            try state.validate(directory: f.vm, root: f.root)
            writes.removeAll()
            try state.reverse(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { writes.append($0) })
            XCTAssertEqual(writes, Array(f.initial.offsets.reversed()))
            XCTAssertEqual(try Data(contentsOf: f.live), f.original)
            XCTAssertEqual(state.cursor, 0); XCTAssertFalse(state.pending)
            try state.validate(directory: f.vm, root: f.root)
        }
    }

    func testEveryLegalFullBlockPrefixValidatesInBothDirections() throws {
        // Exhaust all 4097 possible pwrite-prefix lengths through actual validate.
        let f = try Fixture(original: Data(repeating: 0x11, count: 4096), candidate: Data(repeating: 0x99, count: 4096))
        for reverse in [false, true] {
            var state = f.initial
            state.direction = reverse ? .reverse : .forward
            state.cursor = reverse ? 1 : 0; state.pending = true
            let from = reverse ? f.candidate : f.original, to = reverse ? f.original : f.candidate
            for count in 0...4096 {
                var actual = from
                actual.replaceSubrange(0..<count, with: to.prefix(count))
                try actual.write(to: f.live)
                try state.validate(directory: f.vm, root: f.root)
            }
            var unknown = from; unknown[2048] = 0x37
            try unknown.write(to: f.live)
            XCTAssertThrowsError(try state.validate(directory: f.vm, root: f.root))
            var nonPrefix = from; nonPrefix[4095] = to[4095]
            try nonPrefix.write(to: f.live)
            XCTAssertThrowsError(try state.validate(directory: f.vm, root: f.root))
        }
    }

    func testIdenticalNonemptyBatchAndTailHaveNoChangedOffsets() throws {
        let content = Data(repeating: 0x47, count: 2 * batch + 3)
        let f = try Fixture(original: content, candidate: content)
        XCTAssertEqual(f.initial.offsets, [])
        var state = f.initial, writes = 0
        try state.publish(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in writes += 1 })
        try state.reverse(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in writes += 1 })
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: f.live), content)
    }

    func testPendingPrefixesAtBatchAndTailRecoverWithoutUnknownWrites() throws {
        let f = try fixture(size: 2 * batch + 8195)
        for reverse in [false, true] {
            for index in f.initial.offsets.indices {
                let start = Int(f.initial.offsets[index]), end = min(start + 4096, f.original.count)
                for count in Set([0, 1, (end - start) / 2, end - start - 1, end - start]).sorted() {
                    var state = f.initial
                    state.direction = reverse ? .reverse : .forward
                    state.cursor = reverse ? index + 1 : index; state.pending = true
                    var actual = bytes(f, cursor: state.cursor)
                    let from = reverse ? f.candidate : f.original, to = reverse ? f.original : f.candidate
                    actual.replaceSubrange(start..<end, with: from[start..<end])
                    actual.replaceSubrange(start..<(start + count), with: to[start..<(start + count)])
                    try actual.write(to: f.live)
                    try state.validate(directory: f.vm, root: f.root)
                    if !reverse {
                        XCTAssertThrowsError(try state.publish(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in }))
                    }
                    try state.reverse(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in })
                    XCTAssertEqual(try Data(contentsOf: f.live), f.original)

                    // A byte belonging to neither endpoint must remain untouched.
                    var bad = actual
                    bad[start] = f.original[start] ^ 0x55
                    try bad.write(to: f.live)
                    var rejected = f.initial
                    rejected.direction = reverse ? .reverse : .forward
                    rejected.cursor = reverse ? index + 1 : index; rejected.pending = true
                    XCTAssertThrowsError(try rejected.reverse(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in }))
                    XCTAssertEqual(try Data(contentsOf: f.live), bad)
                }
            }
        }
    }

    func testPublicationAndRestorationFaultRecoveryAtEveryChangedBlock() throws {
        let f = try fixture(size: 2 * batch + 8195)
        for failAt in f.initial.offsets.indices {
            for journalFault in [false, true] {
                try f.original.write(to: f.live)
                var state = f.initial, durable = state
                var writes = 0
                XCTAssertThrowsError(try state.publish(directory: f.vm, root: f.root, save: { next in
                    durable = next
                    if journalFault && next.pending && next.cursor == failAt { throw POSIXError(.ENOSPC) }
                }, afterWrite: { _ in
                    defer { writes += 1 }
                    if !journalFault && writes == failAt { throw POSIXError(.EINTR) }
                }))
                XCTAssertTrue(durable.pending)
                try durable.reverse(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in })
                XCTAssertEqual(try Data(contentsOf: f.live), f.original)
            }
            try f.original.write(to: f.live)
            var state = f.initial
            try state.publish(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in })
            var durable = state, writes = 0
            XCTAssertThrowsError(try state.reverse(directory: f.vm, root: f.root, save: { durable = $0 }, afterWrite: { _ in
                defer { writes += 1 }
                if writes == failAt { throw POSIXError(.EINTR) }
            }))
            XCTAssertTrue(durable.pending)
            try durable.reverse(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in })
            XCTAssertEqual(try Data(contentsOf: f.live), f.original)
        }
    }

    func testArchiveLiveLengthAndIdentityTamperingRefuseBeforeRecovery() throws {
        for fault in ["original", "candidate", "live", "unchanged-live", "truncate", "append", "identity"] {
            let f = try fixture(size: batch + 4097)
            let target = fault == "original" ? f.root.appendingPathComponent(FirmwareKernelDisk.originalName)
                : fault == "candidate" ? f.root.appendingPathComponent(FirmwareKernelDisk.candidateName) : f.live
            var altered = try Data(contentsOf: target)
            if fault == "truncate" { altered.removeLast() }
            else if fault == "append" { altered.append(0x71) }
            else if fault != "identity" { altered[fault == "unchanged-live" ? batch / 2 : batch] ^= 0x55 }
            try altered.write(to: target, options: fault == "identity" ? .atomic : [])
            XCTAssertThrowsError(try f.initial.validate(directory: f.vm, root: f.root), fault)
            var state = f.initial
            XCTAssertThrowsError(try state.reverse(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in }), fault)
            XCTAssertEqual(try Data(contentsOf: target), altered)
        }
        for delta in [-1, 1] {
            let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("vphone-kernel-io-length-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let vm = directory.appendingPathComponent("vm"), backup = directory.appendingPathComponent("backup")
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
            try Data(repeating: 1, count: batch + 3).write(to: vm.appendingPathComponent("Disk.img"))
            try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": VZMacMachineIdentifier().dataRepresentation,
                "diskImage": "Disk.img"], format: .binary, options: 0).write(to: vm.appendingPathComponent("config.plist"))
            let input = directory.appendingPathComponent("candidate.img")
            try Data(repeating: 1, count: batch + 3 + delta).write(to: input)
            XCTAssertThrowsError(try FirmwareKernelDisk.capture(directory: vm, root: backup, candidate: input))
        }
    }

    func testBatchBoundaryPrewriteChangesArePreserved() throws {
        for reverse in [false, true] {
            for fault in ["replace", "edit", "truncate"] {
                let f = try fixture(size: 2 * batch + 8195)
                var state = f.initial
                if reverse { try state.publish(directory: f.vm, root: f.root, save: { _ in }, afterWrite: { _ in }) }
                var external: Data?
                let save: (FirmwareKernelDisk) throws -> Void = { next in
                    guard next.pending, external == nil else { return }
                    let index = reverse ? next.cursor - 1 : next.cursor
                    let offset = Int(next.offsets[index])
                    guard offset >= self.batch else { return }
                    var changed = try Data(contentsOf: f.live)
                    if fault == "truncate" { changed.removeLast() }
                    else if fault == "edit" { changed[offset] ^= 0x55 }
                    try changed.write(to: f.live, options: fault == "replace" ? .atomic : [])
                    external = changed
                }
                if reverse {
                    XCTAssertThrowsError(try state.reverse(directory: f.vm, root: f.root, save: save, afterWrite: { _ in }))
                } else {
                    XCTAssertThrowsError(try state.publish(directory: f.vm, root: f.root, save: save, afterWrite: { _ in }))
                }
                let expected = try XCTUnwrap(external)
                XCTAssertEqual(try Data(contentsOf: f.live), expected)
            }
        }
    }
}

import Darwin
import Foundation
import Img4tool
import VPhoneCore
import XCTest
@testable import FirmwarePatcher

/// Synthetic public publication, with ordinary files and mocked volume tools.
/// Measurements exclude input creation, prepare and final independent readback.
final class FirmwareKernelIOFactorialBenchmarkTests: XCTestCase {
    func testPublication() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VPHONE_KERNEL_IO_FACTORIAL"] == "1" else {
            throw XCTSkip("Only run in a fresh process for the isolated factorial benchmark")
        }
        let size = try XCTUnwrap(Int(env["VPHONE_KERNEL_IO_BENCHMARK_BYTES"] ?? ""))
        let label = try XCTUnwrap(env["VPHONE_KERNEL_IO_BENCHMARK_LABEL"])
        guard size > 1 << 20, size <= 1 << 30, size % 4096 != 0,
              label.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw POSIXError(.EINVAL)
        }
        let fixture = try FirmwareKernelRollbackTests.Fixture()
        let prefix: Data
        do {
            let input = try FileHandle(forReadingFrom: fixture.disk)
            defer { try? input.close() }
            prefix = try XCTUnwrap(input.read(upToCount: 4096))
        }
        XCTAssertEqual(prefix.count, 4096)
        var chunk = Data(count: 1 << 20), seed: UInt64 = 0x6a09e667f3bcc909
        chunk.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for index in bytes.indices {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                bytes[index] = UInt8(truncatingIfNeeded: seed)
            }
        }
        // Fully write the input rather than constructing a sparse file.
        do {
            let output = try FileHandle(forWritingTo: fixture.disk)
            defer { try? output.close() }
            var remaining = size
            while remaining > 0 {
                let count = min(remaining, chunk.count)
                try output.write(contentsOf: chunk.prefix(count)); remaining -= count
            }
            try output.seek(toOffset: 0); try output.write(contentsOf: prefix)
            try output.truncate(atOffset: UInt64(size)); try output.synchronize()
        }
        let desired = try fixture.desired()
        let prepared = try FirmwareKernelUpdate.prepare(in: fixture.vm, plan: desired.plan,
                                                        generation: fixture.firmware.generation)
        let identity = try VPhoneFirmwareIdentity.read(in: fixture.vm)
        var operations = fixture.operations()
        operations.volumes = Self.volumes
        var receipt: FirmwareComponentReceipt.Record?
        var start: UInt64 = 0, end: UInt64 = 0
        print("kernel-io-factorial " + json(["event": "measurement-start", "label": label,
            "operation": "publication", "monotonic_ns": DispatchTime.now().uptimeNanoseconds, "pid": getpid()]))
        try fixture.session { session in
            start = DispatchTime.now().uptimeNanoseconds
            receipt = try FirmwareKernelUpdate.publish(prepared, session: session,
                                                       expected: prepared.binding, operations: operations)
            end = DispatchTime.now().uptimeNanoseconds
        }
        let actual = try XCTUnwrap(receipt)
        let journal = try FirmwareTransaction.readJournal(at: fixture.vm.appendingPathComponent(
            ".firmware-history/" + fixture.currentTransaction() + "/journal.json"))
        let diskState = try XCTUnwrap(journal.kernelDisk)
        XCTAssertEqual(journal.phase, .committed)
        XCTAssertEqual(journal.metadata?.count, 2)
        XCTAssertEqual(diskState.size, UInt64(size))
        XCTAssertEqual(diskState.offsets, [0])
        XCTAssertEqual(diskState.cursor, 1); XCTAssertFalse(diskState.pending)
        XCTAssertEqual(try VPhoneFirmwareIdentity.read(in: fixture.vm), identity)
        let finalSHA = try FirmwareGeneration.fileSHA256(fixture.disk)
        XCTAssertEqual(actual.outputs, [.init(path: "Disk.img", sha256: finalSHA)])
        XCTAssertEqual(diskState.originalSHA256, prepared.diskSHA256)
        XCTAssertEqual(diskState.candidateSHA256, finalSHA)
        print("kernel-io-factorial " + json(["event": "measurement-end", "label": label,
            "operation": "publication", "pid": getpid(), "bytes": size,
            "monotonic_start_ns": start, "monotonic_end_ns": end, "elapsed_ns": end - start,
            "elapsed_seconds": Double(end - start) / 1_000_000_000,
            "original_sha256": prepared.diskSHA256, "candidate_sha256": finalSHA,
            "metadata_count": 2, "offsets": diskState.offsets, "observed_size": diskState.size,
            "result": "passed"]))
    }

    /// Reads only the kernel block. The disk's remaining bytes stay in files,
    /// so mock mount overhead does not allocate or reread the complete input.
    static func volumes(_ transaction: FirmwareTransaction, _ writable: Bool) -> FirmwareInstalledReadback.Operations? {
        let reference = FirmwareKernelRollbackTests.Fixture.volumes(transaction, writable: writable)
        return .init(attach: { image, work in
            let mount = work.appendingPathComponent("factorial-mock-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
            var roots: [String: FirmwareInstalledReadback.Volume] = [:]
            for (name, suffix) in ["system": "s1", "hardware": "s3", "preboot": "s5"] {
                let root = mount.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                roots[name] = .init(device: "disk998" + suffix, root: root)
            }
            let input = try FileHandle(forReadingFrom: image)
            defer { try? input.close() }
            let block = try XCTUnwrap(input.read(upToCount: 4096))
            try FirmwareKernelRollbackTests.Fixture.image(in: block).write(to: roots["preboot"]!.root.appendingPathComponent("kernelcache"))
            let dsc = roots["system"]!.root.appendingPathComponent("System/Cryptexes/OS/System/Library/Caches/com.apple.dyld")
            try FileManager.default.createDirectory(at: dsc, withIntermediateDirectories: true)
            var header = Data(repeating: 0, count: 4096)
            header.replaceSubrange(0..<7, with: Data("dyld_v1".utf8))
            func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
                var le = value.littleEndian
                withUnsafeBytes(of: &le) { header.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
            }
            put(UInt32(0x200), 0x10); put(UInt32(1), 0x14)
            put(UInt64(0x180000000), 0xE0); put(UInt64(4096), 0xE8)
            put(UInt64(0x180000000), 0x200); put(UInt64(4096), 0x208)
            try header.write(to: dsc.appendingPathComponent("dyld_shared_cache_arm64e"))
            return .init(image: image, device: "/dev/disk999", volumes: roots)
        }, inspect: reference.inspect, detach: { attachment in
            if writable {
                let input = try FileHandle(forReadingFrom: attachment.image)
                defer { try? input.close() }
                var block = try XCTUnwrap(input.read(upToCount: 4096))
                let target = attachment.volumes["preboot"]!.root.appendingPathComponent("kernelcache")
                FirmwareKernelRollbackTests.Fixture.setImage(try Data(contentsOf: target), in: &block)
                let output = try FileHandle(forWritingTo: attachment.image)
                defer { try? output.close() }
                try output.write(contentsOf: block); try output.synchronize()
            }
            try FileManager.default.removeItem(at: attachment.volumes["preboot"]!.root.deletingLastPathComponent())
        })
    }

    private func json(_ value: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }
}

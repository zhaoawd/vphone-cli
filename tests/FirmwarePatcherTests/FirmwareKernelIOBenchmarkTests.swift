import Darwin
import Foundation
import Virtualization
import VPhoneCore
import XCTest
@testable import FirmwarePatcher

/// Opt-in only. Select one method per fresh XCTest process; no VM inputs.
final class FirmwareKernelIOBenchmarkTests: XCTestCase {
    func testCapture() throws { try benchmark("capture") }
    func testValidate() throws { try benchmark("validate") }

    private func benchmark(_ operation: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VPHONE_KERNEL_IO_BENCHMARK"] == "1",
              env["VPHONE_KERNEL_IO_BENCHMARK_OPERATION"] == operation else {
            throw XCTSkip("Opt in and select exactly one helper in a fresh XCTest process")
        }
        let label = env["VPHONE_KERNEL_IO_BENCHMARK_LABEL"] ?? "unlabelled"
        guard label.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil, label.count <= 80 else {
            throw NSError(domain: "KernelIOBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid label"])
        }
        let sizeText = env["VPHONE_KERNEL_IO_BENCHMARK_BYTES"] ?? String(512 * 1024 * 1024 + 3)
        guard let size = Int(sizeText), size >= 1024 * 1024 + 1, size <= 1024 * 1024 * 1024,
              size % 4096 != 0 else {
            throw NSError(domain: "KernelIOBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "Size must be >1 MiB, <=1 GiB, and include a partial 4 KiB tail"])
        }
        let readSizeText = env["VPHONE_KERNEL_IO_BENCHMARK_READ_BYTES"] ?? "4096"
        guard let readSize = Int(readSizeText), [4096, 1024 * 1024].contains(readSize) else {
            throw NSError(domain: "KernelIOBenchmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid declared scan read size"])
        }
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("vphone-kernel-io-benchmark-" + UUID().uuidString)
        let vm = directory.appendingPathComponent("vm"), root = directory.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = vm.appendingPathComponent("Disk.img"), candidate = directory.appendingPathComponent("candidate.img")
        let megabyte: Int = 1024 * 1024
        let middleBlock: Int = (size / 2 / 4096) * 4096
        let tailBlock: Int = ((size - 1) / 4096) * 4096
        let changedBlocks: [Int] = [0, megabyte - 4096, megabyte, middleBlock, tailBlock]
        let sortedBlocks: [Int] = Array(Set(changedBlocks)).sorted()
        let expected: [UInt64] = sortedBlocks.map { UInt64($0) }
        // Every byte is written. No truncate-created holes, clonefile or VM paths.
        var chunk = Data(count: 1024 * 1024), seed: UInt64 = 0x6a09e667f3bcc909
        chunk.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for index in bytes.indices {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                bytes[index] = UInt8(truncatingIfNeeded: seed)
            }
        }
        for file in [disk, candidate] {
            try autoreleasepool {
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw POSIXError(.EIO) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                var remaining = size
                while remaining > 0 {
                    let count = min(remaining, chunk.count)
                    try autoreleasepool { try handle.write(contentsOf: chunk.prefix(count)) }
                    remaining -= count
                }
                if file == candidate {
                    for offset in expected {
                        try handle.seek(toOffset: offset)
                        try handle.write(contentsOf: Data([chunk[Int(offset) % chunk.count] ^ 0xff]))
                    }
                }
                try handle.synchronize()
                try handle.close()
            }
        }
        try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": VZMacMachineIdentifier().dataRepresentation,
            "diskImage": "Disk.img"], format: .binary, options: 0).write(to: vm.appendingPathComponent("config.plist"))
        var prepared: FirmwareKernelDisk?
        if operation == "validate" {
            for (source, name) in [(disk, FirmwareKernelDisk.originalName), (candidate, FirmwareKernelDisk.candidateName)] {
                let destination = root.appendingPathComponent(name)
                try FileManager.default.copyItem(at: source, to: destination)
                let handle = try FileHandle(forWritingTo: destination)
                try handle.synchronize(); try handle.close()
            }
            prepared = try FirmwareKernelDisk(identity: VPhoneFirmwareIdentity.read(in: vm),
                originalSHA256: FirmwareGeneration.fileSHA256(disk), candidateSHA256: FirmwareGeneration.fileSHA256(candidate),
                size: UInt64(size), offsets: expected)
        }
        // Setup, writes, fsync and validation-state hashing above are untimed.
        var before = rusage(), after = rusage()
        guard getrusage(RUSAGE_SELF, &before) == 0 else { throw POSIXError(.EIO) }
        print("kernel-io-benchmark " + json(["event": "measurement-start", "label": label, "operation": operation,
            "monotonic_ns": DispatchTime.now().uptimeNanoseconds, "pid": getpid()]))
        var offsets: [UInt64] = []
        var observed = prepared, failure: (any Error)?
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            if let prepared {
                try prepared.validate(directory: vm, root: root)
            } else {
                observed = try FirmwareKernelDisk.capture(directory: vm, root: root, candidate: candidate)
            }
        } catch {
            failure = error
        }
        let end = DispatchTime.now().uptimeNanoseconds
        if let observed {
            offsets = observed.offsets
            if observed.size != UInt64(size) || offsets != expected {
                failure = NSError(domain: "KernelIOBenchmark", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Captured size or offsets differ"])
            }
        }
        guard getrusage(RUSAGE_SELF, &after) == 0 else { throw POSIXError(.EIO) }
        print("kernel-io-benchmark " + json(["event": "measurement-end", "label": label, "operation": operation,
            "pid": getpid(), "directory": directory.path, "bytes": size, "elapsed_ns": end - start,
            "elapsed_seconds": Double(end - start) / 1_000_000_000, "monotonic_start_ns": start, "monotonic_end_ns": end,
            "readsize": readSize, "readsize_source": "runner declaration; correlate with auditlogger, not an observed syscall count",
            "expected_offsets": expected, "offsets": offsets, "offsets_match": offsets == expected,
            "observed_size": observed.map { $0.size as Any } ?? NSNull(),
            "original_sha256": observed.map { $0.originalSHA256 as Any } ?? NSNull(),
            "candidate_sha256": observed.map { $0.candidateSHA256 as Any } ?? NSNull(),
            "result": failure == nil ? "passed" : "failed", "error": failure.map { String(describing: $0) as Any } ?? NSNull(),
            "rss_peak_before_bytes": before.ru_maxrss, "rss_peak_after_bytes": after.ru_maxrss,
            "rss_peak_growth_bytes": max(0, after.ru_maxrss - before.ru_maxrss), "cache_policy": "warm; no cache eviction"]))
        if let failure { throw failure }
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

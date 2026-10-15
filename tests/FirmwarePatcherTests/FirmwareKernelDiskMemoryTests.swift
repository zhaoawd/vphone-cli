import Darwin
import Foundation
import Virtualization
import VPhoneCore
import XCTest
@testable import FirmwarePatcher

final class FirmwareKernelDiskMemoryTests: XCTestCase {
    func testScansUseBoundedMemory() throws {
        for operation in ["capture", "validate", "publish", "reverse"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "FirmwarePatcherTests.FirmwareKernelDiskMemoryTests/testScanChild",
                               Bundle(for: Self.self).bundleURL.path]
            child.environment = ProcessInfo.processInfo.environment.merging(["VPHONE_KERNEL_DISK_MEMORY_CHILD": operation]) { _, new in new }
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0, "\(operation) must release each block before reading the next")
        }
    }

    func testScanChild() throws {
        guard let operation = ProcessInfo.processInfo.environment["VPHONE_KERNEL_DISK_MEMORY_CHILD"] else {
            throw XCTSkip("Only invoked by the isolated memory regression")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kernel-disk-memory-" + UUID().uuidString)
        let vm = root.appendingPathComponent("vm"), backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = vm.appendingPathComponent("Disk.img"), candidate = root.appendingPathComponent("candidate.img")
        let writes = operation == "publish" || operation == "reverse"
        let size = UInt64((writes ? 16 : 64) * 1024 * 1024 + 3)
        try autoreleasepool {
            for file in [disk, candidate] {
                XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: size)
                if file == candidate {
                    if writes {
                        try handle.seek(toOffset: 0)
                        let chunk = Data(repeating: 1, count: 1024 * 1024)
                        for _ in 0..<16 { try handle.write(contentsOf: chunk) }
                        try handle.write(contentsOf: Data([1, 1, 1]))
                    } else {
                        try handle.seek(toOffset: size - 1)
                        try handle.write(contentsOf: Data([1]))
                    }
                }
                try handle.close()
            }
            try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": VZMacMachineIdentifier().dataRepresentation,
                "diskImage": "Disk.img"], format: .xml, options: 0).write(to: vm.appendingPathComponent("config.plist"))
        }
        let expectedOffset = size - 3
        let prepared: FirmwareKernelDisk? = try autoreleasepool { () throws -> FirmwareKernelDisk? in
            guard operation != "capture" else { return nil }
            try FileManager.default.copyItem(at: disk, to: backup.appendingPathComponent(FirmwareKernelDisk.originalName))
            try FileManager.default.copyItem(at: candidate, to: backup.appendingPathComponent(FirmwareKernelDisk.candidateName))
            var state = try FirmwareKernelDisk(identity: VPhoneFirmwareIdentity.read(in: vm),
                originalSHA256: FirmwareGeneration.fileSHA256(disk), candidateSHA256: FirmwareGeneration.fileSHA256(candidate),
                size: size, offsets: writes ? Array(stride(from: UInt64(0), to: size, by: FirmwareKernelDisk.blockSize)) : [expectedOffset])
            if operation == "reverse" {
                let handle = try FileHandle(forWritingTo: disk)
                let chunk = Data(repeating: 1, count: 1024 * 1024)
                for _ in 0..<16 { try handle.write(contentsOf: chunk) }
                try handle.write(contentsOf: Data([1, 1, 1]))
                try handle.close()
                state.cursor = state.offsets.count
            }
            return state
        }
        var before = rusage(), after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        if var prepared {
            if operation == "publish" {
                try prepared.publish(directory: vm, root: backup, save: { _ in }, afterWrite: { _ in })
                XCTAssertEqual(prepared.cursor, prepared.offsets.count)
            } else if operation == "reverse" {
                try prepared.reverse(directory: vm, root: backup, save: { _ in }, afterWrite: { _ in })
                XCTAssertEqual(prepared.cursor, 0)
            } else {
                try prepared.validate(directory: vm, root: backup)
            }
        } else {
            let captured = try FirmwareKernelDisk.capture(directory: vm, root: backup, candidate: candidate)
            XCTAssertEqual(captured.size, size)
            XCTAssertEqual(captured.offsets, [expectedOffset])
        }
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        let growth = after.ru_maxrss - before.ru_maxrss
        print("kernel-disk-memory operation=\(operation) bytes=\(size) rss_before=\(before.ru_maxrss) rss_after=\(after.ru_maxrss) growth=\(growth)")
        // Darwin reports bytes. Retaining complete inputs across 4 KiB reads
        // exceeds these bounds; live block buffers do not.
        XCTAssertLessThan(growth, (writes ? 16 : 64) * 1024 * 1024, "\(operation) retained block buffers")
    }
}

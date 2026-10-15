import Darwin
import Foundation
import Virtualization
import VPhoneCore
import XCTest
@testable import FirmwarePatcher

final class FirmwareKernelIOFusionTests: XCTestCase {
    private final class CaptureFixture {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("kernel-fusion-" + UUID().uuidString)
        var vm: URL { root.appendingPathComponent("vm") }
        var backup: URL { root.appendingPathComponent("backup") }
        var disk: URL { vm.appendingPathComponent("Disk.img") }
        var candidate: URL { root.appendingPathComponent("candidate.img") }
        let original = Data(repeating: 0x41, count: (1 << 20) + 3)
        var replacement: Data { var data = original; data[0] = 0x71; data[data.count - 1] = 0x72; return data }
        init() throws {
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
            try original.write(to: disk); try replacement.write(to: candidate)
            try PropertyListSerialization.data(fromPropertyList: [
                "machineIdentifier": VZMacMachineIdentifier().dataRepresentation, "diskImage": "Disk.img",
            ], format: .binary, options: 0).write(to: vm.appendingPathComponent("config.plist"))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    func testFusedCaptureHashesActualShortReadsAndRetriesEINTR() throws {
        let f = try CaptureFixture()
        var calls = 0
        let result = try FirmwareKernelDisk.capture(directory: f.vm, root: f.backup, candidate: f.candidate) { fd, buffer, count, offset in
            calls += 1
            if calls == 1 { return .init(count: -1, error: EINTR) }
            return FirmwareKernelDiskBatchReader.systemRead(fd, buffer, min(count, 65537), offset)
        }
        XCTAssertGreaterThan(calls, 30)
        XCTAssertEqual(result.originalSHA256, VPhoneCreateDigest.sha256(f.original))
        XCTAssertEqual(result.candidateSHA256, VPhoneCreateDigest.sha256(f.replacement))
        XCTAssertEqual(result.offsets, [0, 1 << 20])
        try result.validate(directory: f.vm, root: f.backup)
    }

    func testFusedCaptureRejectsPostSyncBackupChanges() throws {
        for name in [FirmwareKernelDisk.originalName, FirmwareKernelDisk.candidateName] {
            for fault in ["edit", "grow", "truncate", "replace", "symlink", "hardlink", "rewrite-identical"] {
                let f = try CaptureFixture()
                let target = f.backup.appendingPathComponent(name)
                var fired = false
                XCTAssertThrowsError(try FirmwareKernelDisk.capture(directory: f.vm, root: f.backup, candidate: f.candidate) { fd, buffer, count, offset in
                    if !fired {
                        fired = true
                        do {
                            var bytes = try Data(contentsOf: target)
                            if fault == "edit" { bytes[bytes.count - 1] ^= 0xff }
                            if fault == "grow" { bytes.append(0x55) }
                            if fault == "truncate" { bytes.removeLast() }
                            if fault == "symlink" || fault == "hardlink" {
                                let saved = f.backup.appendingPathComponent("saved")
                                try FileManager.default.moveItem(at: target, to: saved)
                                if fault == "symlink" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: saved) }
                                else { try FileManager.default.linkItem(at: saved, to: target) }
                            } else {
                                try bytes.write(to: target, options: fault == "replace" ? .atomic : [])
                            }
                        } catch {
                            XCTFail("Fault injection failed: \(error)")
                            return .init(count: -1, error: EIO)
                        }
                    }
                    return FirmwareKernelDiskBatchReader.systemRead(fd, buffer, count, offset)
                }, "\(name): \(fault)")
                XCTAssertTrue(fired)
                XCTAssertEqual(try Data(contentsOf: f.disk), f.original)
            }
        }
    }

    func testFusedCaptureRetainsFinalLiveDiskRecheck() throws {
        let f = try CaptureFixture()
        var fired = false
        XCTAssertThrowsError(try FirmwareKernelDisk.capture(directory: f.vm, root: f.backup, candidate: f.candidate) { fd, buffer, count, offset in
            if !fired {
                fired = true
                do {
                    let h = try FileHandle(forWritingTo: f.disk)
                    defer { try? h.close() }
                    try h.write(contentsOf: Data([0x99]))
                } catch {
                    XCTFail("Fault injection failed: \(error)")
                    return .init(count: -1, error: EIO)
                }
            }
            return FirmwareKernelDiskBatchReader.systemRead(fd, buffer, count, offset)
        })
        XCTAssertEqual(try Data(contentsOf: f.disk).first, 0x99)
    }

    func testFusedCaptureRejectsEarlyEOFAndReadFailure() throws {
        for fault in ["eof", "error"] {
            let f = try CaptureFixture()
            var calls = 0
            XCTAssertThrowsError(try FirmwareKernelDisk.capture(directory: f.vm, root: f.backup, candidate: f.candidate) { fd, buffer, count, offset in
                calls += 1
                if calls == 2 { return .init(count: fault == "eof" ? 0 : -1, error: fault == "eof" ? 0 : EIO) }
                return FirmwareKernelDiskBatchReader.systemRead(fd, buffer, min(17, count), offset)
            })
            XCTAssertEqual(calls, 2)
        }
    }

    func testExpectedMountDigestAndReadonlyBoundaryChanges() throws {
        for fault in ["success", "before", "attach", "inspect", "body", "detach", "detach-error"] {
            let f = try FirmwareKernelRollbackTests.Fixture()
            let t = try FirmwareReceiptPublicationTests().begin(f.firmware)
            let expected = try FirmwareGeneration.fileSHA256(f.disk)
            let original = FirmwareKernelRollbackTests.Fixture.volumes(t, writable: false)
            var attached = 0, detached = 0, inspected = 0
            func change() throws {
                let h = try FileHandle(forWritingTo: f.disk)
                defer { try? h.close() }
                try h.seekToEnd(); try h.write(contentsOf: Data([0x99]))
            }
            if fault == "before" { try change() }
            let operations = FirmwareInstalledReadback.Operations(attach: { image, work in
                attached += 1
                let result = try original.attach(image, work)
                if fault == "attach" { try change() }
                return result
            }, inspect: { attachment in
                inspected += 1
                if fault == "inspect", inspected == 2 { try change() }
                return try original.inspect(attachment)
            }, detach: { attachment in
                detached += 1
                try original.detach(attachment)
                if fault == "detach" { try change() }
                if fault == "detach-error" { throw POSIXError(.EIO) }
            })
            let run = {
                try FirmwareKernelMount.withVolumes(image: f.disk, transaction: t, writable: false,
                    expectedSHA256: expected, operations: operations) { _ in
                    if fault == "body" { try change() }
                }
            }
            if fault == "success" { XCTAssertNoThrow(try run()) }
            else { XCTAssertThrowsError(try run(), fault) }
            XCTAssertEqual(attached, fault == "before" ? 0 : 1)
            XCTAssertEqual(detached, fault == "before" ? 0 : 1)
        }
    }

    func testExpectedDigestCannotAuthorizeWritableMount() throws {
        let f = try FirmwareKernelRollbackTests.Fixture()
        let t = try FirmwareReceiptPublicationTests().begin(f.firmware)
        var attached = false
        let operations = FirmwareInstalledReadback.Operations(attach: { _, _ in
            attached = true; throw POSIXError(.EIO)
        }, inspect: { _ in throw POSIXError(.EIO) }, detach: { _ in })
        XCTAssertThrowsError(try FirmwareKernelMount.withVolumes(image: f.disk, transaction: t, writable: true,
            expectedSHA256: FirmwareGeneration.fileSHA256(f.disk), operations: operations) { _ in })
        XCTAssertFalse(attached)
    }

    func testTransactionTailRejectsDiskChangeDuringPostMountSourceRecheck() throws {
        let f = try FirmwareKernelRollbackTests.Fixture()
        let desired = try f.desired()
        let prepared = try FirmwareKernelUpdate.prepare(in: f.vm, plan: desired.plan, generation: f.firmware.generation)
        var operations = f.operations()
        let factory = operations.volumes
        var afterPublishedDetach = false, fired = false
        operations.volumes = { transaction, writable in
            let original = factory(transaction, writable)!
            return .init(attach: original.attach, inspect: original.inspect, detach: { attachment in
                try original.detach(attachment)
                if !writable && attachment.image == f.disk { afterPublishedDetach = true }
            })
        }
        XCTAssertThrowsError(try FirmwareInstalledOrigin.withVerifiedSource(version: "2.6.2",
            executable: f.executable, effectiveExecutable: f.executable, recheck: {
                if afterPublishedDetach && !fired {
                    fired = true
                    let h = try FileHandle(forWritingTo: f.disk)
                    defer { try? h.close() }
                    try h.seek(toOffset: 8192); try h.write(contentsOf: Data([0x99]))
                }
            }) { session in
                try FirmwareKernelUpdate.publish(prepared, session: session, expected: prepared.binding, operations: operations)
            }) { error in
                XCTAssertEqual(error.localizedDescription, "Installed target changed during qualification")
            }
        XCTAssertTrue(fired)
        XCTAssertEqual(try Data(contentsOf: f.disk)[8192], 0x99)
        XCTAssertThrowsError(try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in }))
        XCTAssertEqual(try Data(contentsOf: f.disk)[8192], 0x99)
    }
}

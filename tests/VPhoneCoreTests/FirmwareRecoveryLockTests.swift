import Foundation
import Testing
@testable import VPhoneCore

struct FirmwareRecoveryLockTests {
    @Test func pendingCFWHidesOriginsUntilRecoveryCompletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = try VPhoneMachineBinding(bundle: "1.0.0", guestEnvironment: "1.0.0")
        try JSONEncoder().encode(binding).write(to: root.appendingPathComponent("launchpad.json"))
        #expect(try VPhoneMachineBinding.snapshot(root)?.binding == binding)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".cfw_disk.pending"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try VPhoneMachineBinding.snapshot(root) }
    }
    @Test func pendingCFWPreventsBootAndMutationWhileInspectionCanAcquireLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".cfw_disk.interrupted"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for operation in ["boot", "dfu", "cfw", "fw-patch", "export", "delete"] {
            #expect(throws: (any Error).self) { try VPhoneVMLock(directory: root, operation: operation) }
            #expect(!VPhoneVMLockProbe.isLockHeld(directory: root))
        }
        for operation in [VPhoneVMOperation.cfwRecord, VPhoneVMOperation.fwReceipts] {
            let lock = try VPhoneVMLock(directory: root, operation: operation)
            withExtendedLifetime(lock) { #expect(VPhoneVMLockProbe.isLockHeld(directory: root)) }
        }
        do {
            try VPhoneBundleGuard.withBundleLock(directory: root, operation: VPhoneVMOperation.boot) { _ in
                Issue.record("Pending CFW transaction allowed boot")
            }
            Issue.record("Expected CFW recovery diagnostic")
        } catch {
            #expect(String(describing: error).contains("Pending CFW disk transaction"))
        }
    }

    @Test func pendingFirmwarePreventsBootAndOfflineMutationButAllowsRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".firmware-transaction"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for operation in ["boot", "dfu", "cfw", "export", "fw-prepare", "delete"] {
            #expect(throws: (any Error).self) { try VPhoneVMLock(directory: root, operation: operation) }
            #expect(!VPhoneVMLockProbe.isLockHeld(directory: root))
        }
        do {
            try VPhoneBundleGuard.withBundleLock(directory: root, operation: "export") { _ in
                Issue.record("Pending transaction allowed an offline operation")
            }
            Issue.record("Expected firmware recovery diagnostic")
        } catch {
            #expect(String(describing: error).contains("patch-firmware --recover"))
        }
        let lock = try VPhoneVMLock(directory: root, operation: VPhoneVMOperation.fwPatch)
        withExtendedLifetime(lock) { #expect(VPhoneVMLockProbe.isLockHeld(directory: root)) }
    }
}

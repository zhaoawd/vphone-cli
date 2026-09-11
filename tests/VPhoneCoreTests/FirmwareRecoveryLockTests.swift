import Foundation
import Testing
@testable import VPhoneCore

struct FirmwareRecoveryLockTests {
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

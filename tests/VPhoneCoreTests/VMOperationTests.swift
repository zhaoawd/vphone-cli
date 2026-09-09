@testable import VPhoneCore
import Foundation
import Testing

/// The operation vocabulary is the single source both the lock holder and the
/// reader compare against, so its shape is asserted directly.
struct VMOperationTests {
    private func record(_ operation: String, pid: Int32 = 4242) -> VPhoneVMRuntimeState {
        VPhoneVMRuntimeState(
            bundleIdentifier: "1:2", bundlePath: "/vm", pid: pid,
            instanceID: "INSTANCE", startedAt: Date(), operation: operation)
    }

    @Test func allVocabularyHasNoDuplicates() {
        let all = VPhoneVMOperation.all
        #expect(Set(all).count == all.count)
    }

    @Test func vmLifetimeIsExactlyBootAndDFU() {
        #expect(VPhoneVMOperation.vmLifetime == [VPhoneVMOperation.boot, VPhoneVMOperation.dfu])
    }

    @Test func dfuRecordIsBothDFUAndBoot() {
        let r = record(VPhoneVMOperation.dfu)
        #expect(r.isDFUOperation)
        #expect(r.isBootOperation)
    }

    @Test func bootRecordIsBootButNotDFU() {
        let r = record(VPhoneVMOperation.boot)
        #expect(r.isBootOperation)
        #expect(!r.isDFUOperation)
    }

    @Test func offlineRecordIsNeitherBootNorDFU() {
        let r = record(VPhoneVMOperation.config)
        #expect(!r.isBootOperation)
        #expect(!r.isDFUOperation)
    }
}

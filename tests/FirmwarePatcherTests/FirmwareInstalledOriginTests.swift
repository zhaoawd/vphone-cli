import Foundation
import Testing
import VPhoneCore
@testable import FirmwarePatcher

@Suite struct FirmwareInstalledOriginTests {
    @Test func expiredStoreCallbackCannotAuthorizeOrigin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("vphone-cli")
        try Data("trusted executable".utf8).write(to: executable)
        var escaped: FirmwareInstalledOrigin.Session?
        try FirmwareInstalledOrigin.withVerifiedSource(version: "2.6.2", executable: executable,
            effectiveExecutable: executable, recheck: {}) { session in
            try session.recheck()
            escaped = session
        }
        #expect(throws: (any Error).self) { try escaped?.recheck() }
    }
    @Test func differentOrChangedEffectiveExecutableCannotQualify() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("vphone-cli")
        let other = directory.appendingPathComponent("other")
        try Data("trusted executable".utf8).write(to: executable)
        try Data("trusted executable".utf8).write(to: other)
        #expect(throws: (any Error).self) {
            try FirmwareInstalledOrigin.withVerifiedSource(version: "2.6.2", executable: executable,
                effectiveExecutable: other, recheck: {}) { _ in }
        }
        #expect(throws: (any Error).self) {
            try FirmwareInstalledOrigin.withVerifiedSource(version: "2.6.2", executable: executable,
                effectiveExecutable: executable, recheck: {}) { session in
                try Data("changed executable".utf8).write(to: executable)
                try session.recheck()
            }
        }
    }
}

extension FirmwareInstalledOriginTests {
    @Test func decodedRecordsCannotReplaceActualProducer() throws {
        let fixture = try FirmwareComponentReceiptTests.Fixture(kernelInput: Data([0]))
        let transaction = try FirmwareReceiptPublicationTests().begin(fixture)
        let executable = transaction.work.appendingPathComponent("vphone-cli")
        try Data("verified executable".utf8).write(to: executable)
        // The real producer must parse and patch this synthetic non-kernel
        // input; a matching saved report is insufficient to manufacture proof.
        _ = try FirmwareInstalledOrigin.withVerifiedSource(version: "2.6.2", executable: executable,
            effectiveExecutable: executable, recheck: {}) { session in
            #expect(throws: (any Error).self) {
                try session.produceBinary(component: "kernelcache", transaction: transaction)
            }
        }
    }
}

extension FirmwareInstalledOriginTests {
    @Test(arguments: ["success", "source", "output", "binding", "write", "fsync", "after-origin"])
    func qualifiedKernelCommitPreservesOtherLayersAndRestoresMetadata(_ fault: String) throws {
        let f = try FirmwareComponentReceiptTests.Fixture(kernelInput: Data([0]))
        let old = Data(#"{"bundle":"2.6.1","kernel":"2.4.0","guestEnvironment":"2.5.0","bootChain":"2.3.0"}"#.utf8)
        let binding = f.vm.appendingPathComponent("launchpad.json")
        try old.write(to: binding)
        let expected = try #require(try VPhoneMachineBinding.snapshot(f.vm))
        let oldReceipt = Data("prior receipt exact bytes".utf8)
        let receiptURL = f.vm.appendingPathComponent(".firmware-component-receipts.json")
        try oldReceipt.write(to: receiptURL)
        var injected = false
        let t = try FirmwareReceiptPublicationTests().begin(f, inject: { event in
            if fault == "write", event == .beforeMetadataWrite("launchpad.json") { injected = true; throw POSIXError(.EACCES) }
            if fault == "fsync", event == .beforeMetadataSync("launchpad.json") { injected = true; throw POSIXError(.EIO) }
            if fault == "after-origin", event == .afterPublish("launchpad.json") { injected = true; throw POSIXError(.EINTR) }
        })
        try FirmwareReceiptPublicationTests().prepare(f, t)
        let executable = f.generationFixture.root.appendingPathComponent("vphone-cli")
        try Data("verified executable".utf8).write(to: executable)
        let mount = t.work.appendingPathComponent("preboot")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let target = mount.appendingPathComponent("kernelcache")
        try Data([1]).write(to: target)
        let operations = FirmwareInstalledReadbackTests.operations(image: f.generationFixture.disk, root: mount)
        let originals = try FirmwareGeneration.originalURLs(in: f.vm, id: f.generation.id)
        let source = try #require(originals.first { $0.lastPathComponent.contains("Restore") }).appendingPathComponent("kernelcache.research.vphone600")
        try FirmwareInstalledOrigin.withVerifiedSource(version: "2.6.2", executable: executable,
            effectiveExecutable: executable, recheck: {}) { session in
            let produced = try session.produceBinary(component: "kernelcache", transaction: t, producer: { _, input, plan in
                #expect(input == Data([0]))
                let actual = RequiredDeclarationEvidenceTests.complete(plan).allRecords.filter { $0.component.lowercased() == "kernelcache" }
                let records = actual.enumerated().map { index, record in
                    PatchRecord(patchID: record.patchID, component: record.component, fileOffset: 0,
                        originalBytes: Data([index == 0 ? 0 : 1]), patchedBytes: Data([1]), description: "synthetic actual producer")
                }
                return (Data([1]), records)
            })
            if fault == "source" { try Data([2]).write(to: source) }
            if fault == "output" { try Data([1, 2]).write(to: target) }
            if fault == "binding" { try Data(#"{"bundle":"2.6.3"}"#.utf8).write(to: binding) }
            if fault == "success" {
                _ = try session.commitBinary(produced, transaction: t, expected: expected, readback: operations)
                let next = try #require(try VPhoneMachineBinding.snapshot(f.vm)).binding
                #expect(next.kernel == "2.6.2")
                #expect(next.bundle == "2.6.1" && next.guestEnvironment == "2.5.0" && next.bootChain == "2.3.0")
            } else {
                #expect(throws: (any Error).self) { try session.commitBinary(produced, transaction: t, expected: expected, readback: operations) }
                #expect(t.journalSnapshot.phase != .committed)
            }
        }
        if ["write", "fsync", "after-origin"].contains(fault) { #expect(injected) }
        if fault != "success" && fault != "source" && fault != "binding" {
            _ = try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in })
            #expect(try Data(contentsOf: binding) == old)
            #expect(try Data(contentsOf: receiptURL) == oldReceipt)
        }
    }
}

extension FirmwareInstalledOriginTests {
    @Test func oldVersionAndLostLiveStoreQualificationAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("vphone-cli")
        try Data("source".utf8).write(to: executable)
        #expect(throws: (any Error).self) {
            try FirmwareInstalledOrigin.withVerifiedSource(version: "2.5.0", executable: executable, effectiveExecutable: executable, recheck: {}) { _ in }
        }
        var valid = true
        #expect(throws: (any Error).self) {
            try FirmwareInstalledOrigin.withVerifiedSource(version: "2.6.2", executable: executable, effectiveExecutable: executable,
                recheck: { if !valid { throw POSIXError(.EACCES) } }) { session in
                valid = false
                try session.recheck()
            }
        }
    }
    @Test func singleBootChainComponentCannotPublishLayer() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let t = try FirmwareReceiptPublicationTests().begin(f)
        let executable = t.work.appendingPathComponent("vphone-cli")
        try Data("source".utf8).write(to: executable)
        _ = try FirmwareInstalledOrigin.withVerifiedSource(version: "2.6.2", executable: executable, effectiveExecutable: executable, recheck: {}) { session in
            #expect(throws: (any Error).self) { try session.produceBinary(component: "DeviceTree", transaction: t) }
        }
        #expect(t.journalSnapshot.phase == .building)
        #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent("launchpad.json").path))
    }
}

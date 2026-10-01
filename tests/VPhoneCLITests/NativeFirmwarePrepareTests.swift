import ArgumentParser
import Darwin
import Foundation
import Testing
import VPhoneArchiveKit
import VPhoneCore
@testable import vphone_cli

@Suite(.serialized)
struct NativeFirmwarePrepareTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func archive(_ root: URL, cloud: Bool) throws -> URL {
        let tree = root.appendingPathComponent(cloud ? "cloud-files" : "phone-files")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let keys = ["LLB", "iBSS", "iBEC", "iBoot", "Ap,RestoreSecurePageTableMonitor",
            "Ap,RestoreTrustedExecutionMonitor", "Ap,SecurePageTableMonitor", "Ap,TrustedExecutionMonitor",
            "DeviceTree", "RestoreDeviceTree", "SEP", "RestoreSEP", "KernelCache", "RestoreKernelCache",
            "RecoveryMode", "RestoreRamDisk", "RestoreTrustCache", "Ap,SystemVolumeCanonicalMetadata",
            "OS", "StaticTrustCache", "SystemVolume"]
        let components = Dictionary(uniqueKeysWithValues: keys.map { ($0, ["Info": ["Path": "Firmware/test.im4p"]]) })
        let identities: [[String: Any]] = cloud ? ["vresearch101ap", "vphone600ap"].flatMap { device in
            ["Release", "Research"].map { variant in
                ["Info": ["DeviceClass": device, "Variant": variant], "Manifest": components] as [String: Any]
            }
        } : [["Info": ["DeviceClass": "d47ap", "Variant": "Erase"], "Manifest": components]]
        let manifest: [String: Any] = [
            "ProductVersion": "26.1", "ProductBuildVersion": "23B85",
            "SupportedProductTypes": cloud ? ["Cloud"] : ["iPhone17,3"],
            "ManifestVersion": 1, "BuildIdentities": identities,
            "DeviceMap": [["BoardConfig": cloud ? "vresearch101ap" : "d47ap"]],
            "SupportedProductTypeIDs": ["DFU": [1], "Recovery": [2]],
            "SystemRestoreImageFileSystems": ["User": "APFS"],
        ]
        for name in ["BuildManifest.plist", "Restore.plist"] {
            try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
                .write(to: tree.appendingPathComponent(name))
        }
        let paths = ["kernelcache.test", "Firmware/test.im4p", "shared.dmg", "Firmware/shared.dmg.trustcache"]
            + ["agx", "all_flash", "ane", "dfu", "pmp"].map { "Firmware/\($0)/component" }
        for path in paths {
            let file = tree.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((cloud ? "cloud" : "phone").utf8).write(to: file)
        }
        let out = root.appendingPathComponent(cloud ? "cloud.ipsw" : "phone.ipsw")
        try VPhoneArchiveWriter.create(archive: out, from: tree, format: .gnutar)
        return out
    }

    @Test func explicitBackendAndClassicDefault() throws {
        #expect(try VPhoneFWPrepareCommand.parse(["test"]).prepareBackend == .script)
        #expect(try VPhoneFWPrepareCommand.parse(["test", "--prepare-backend", "native"]).prepareBackend == .native)
        #expect(throws: (any Error).self) {
            _ = try VPhoneFWPrepareCommand.parse(["test", "--prepare-backend", "automatic"])
        }
        #expect(try VPhoneVMCreateCommand.parse(["test"]).prepareBackend == nil)
        #expect(try VPhoneVMCreateCommand.parse(["test", "--prepare-backend", "native"]).prepareBackend == .native)
        #expect(try VPhoneVMCreateCommand.parse(["test", "--resume"]).prepareBackend == nil)
        #expect(throws: (any Error).self) {
            _ = try VPhoneVMCreateCommand.parse(["test", "--prepare-backend", "automatic"])
        }
    }

    @Test func localSourcesRejectUnsupportedRequestsAndResolveRelativePaths() throws {
        for pair: (String?, String?, Bool) in [(nil, "/cloud.ipsw", false), ("", "/cloud.ipsw", false),
            ("https://example.invalid/phone.ipsw", "/cloud.ipsw", false),
            ("/phone.ipsw", "file:///cloud.ipsw", false), ("/phone.ipsw", "/cloud.ipsw", true)] {
            #expect(throws: (any Error).self) {
                try VPhoneNativeFirmwarePreparer.localSources(iphoneSource: pair.0, cloudosSource: pair.1, isLess: pair.2)
            }
        }
        let directory = URL(fileURLWithPath: "/local-ipsws", isDirectory: true)
        let sources = try VPhoneNativeFirmwarePreparer.localSources(
            iphoneSource: "phone.ipsw", cloudosSource: "./cloud.ipsw", isLess: false, relativeTo: directory)
        #expect(sources.iphone.path == "/local-ipsws/phone.ipsw")
        #expect(sources.cloudos.path == "/local-ipsws/cloud.ipsw")
    }

    @Test func nativePublicationBeforeCheckpointCommitCanResumeAndReverify() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let phone = try archive(root, cloud: false), cloud = try archive(root, cloud: true)
        let vm = root.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: false)
        let stages = NativePrepareCheckpointStages(bundle: vm)
        let options = VPhoneCreateEffectiveOptions(variant: "regular", iphoneSource: phone.path,
            cloudosSource: cloud.path, spoofBuild: nil, forceDscMaxSlide: false, enableFrida: false,
            cpuCount: 8, memoryMb: 8192, diskSizeGb: 64, prepareBackend: .native)
        let interrupted = VPhoneCreateRunner(executor: stages, verifier: stages, prober: stages,
            storeHooks: .init(inject: { step, checkpoint in
                if step == .rename, checkpoint.record(.prepare).status == .succeeded {
                    throw CocoaError(.fileWriteUnknown)
                }
            }), log: { _ in }, keepArtifacts: true)
        #expect(throws: VPhoneCreateRunError.self) {
            try interrupted.create(bundleURL: vm, options: options, iphoneSource: phone.path, cloudosSource: cloud.path)
        }
        let first = try VPhoneCreateCheckpointStore.load(bundleURL: vm).checkpoint
        #expect(first.record(.prepare).status == .running)
        #expect(VPhoneCreateLiveStages.restoreTree(vm) != nil)
        let resumed = VPhoneCreateRunner(executor: stages, verifier: stages, prober: stages,
            log: { _ in }, keepArtifacts: true)
        // Later stages are deliberately stopped; no patch, restore or boot executes.
        #expect(throws: VPhoneCreateRunError.self) { try resumed.resume(bundleURL: vm) }
        let second = try VPhoneCreateCheckpointStore.load(bundleURL: vm).checkpoint
        #expect(second.record(.prepare).status == .succeeded)
        #expect(second.record(.prepare).history.first?.status == .running)
        #expect(second.record(.prepare).evidence["prepare_backend"] == "native")
        #expect(second.record(.patch).status == .failed)
        #expect(second.artifact("restore_tree")?.availability == .available)
        #expect(stages.prepareRuns == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: vm.path)
            .filter { $0.hasPrefix(".firmware-prepare-backup-") }.count == 1)
        // Skip prepare on the next resume, re-read its actual manifests and compare its fingerprint.
        #expect(throws: VPhoneCreateRunError.self) { try resumed.resume(bundleURL: vm) }
        let third = try VPhoneCreateCheckpointStore.load(bundleURL: vm).checkpoint
        #expect(stages.prepareRuns == 2)
        #expect(third.attempts.last?.checks["verify.prepare"] == "verified")
        #expect(third.effectiveOptions.effectivePrepareBackend == .native)
        #expect(third.artifact("restore_tree")?.availability == .available)
    }

    @Test func checkpointRerunPreservesPreviousTreeOnlyAfterManifestSuccess() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let phone = try archive(root, cloud: false), cloud = try archive(root, cloud: true)
        let vm = root.appendingPathComponent("vm")
        let previous = vm.appendingPathComponent("iPhone17,3_26.1_23B85_Restore")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data("patched previous tree".utf8).write(to: previous.appendingPathComponent("marker"))
        #expect(throws: (any Error).self) {
            try VPhoneNativeFirmwarePreparer.prepare(iPhone: phone, cloudOS: cloud, bundle: vm,
                preserveExistingRestore: true, generateManifest: { _, _ in throw CocoaError(.fileReadCorruptFile) })
        }
        #expect(try Data(contentsOf: previous.appendingPathComponent("marker")) == Data("patched previous tree".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: vm.path).filter { $0.hasPrefix(".firmware-prepare-") }.isEmpty)
        let prepared = try VPhoneNativeFirmwarePreparer.prepare(iPhone: phone, cloudOS: cloud, bundle: vm,
            preserveExistingRestore: true, generateManifest: { _, _ in
                #expect(FileManager.default.fileExists(atPath: previous.appendingPathComponent("marker").path))
            })
        #expect(prepared.path == previous.path)
        #expect(!FileManager.default.fileExists(atPath: previous.appendingPathComponent("marker").path))
        let backup = try #require(FileManager.default.contentsOfDirectory(at: vm, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".firmware-prepare-backup-") })
        #expect(try Data(contentsOf: backup.appendingPathComponent(previous.lastPathComponent + "/marker")) == Data("patched previous tree".utf8))
        #expect(try backup.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func preservationRefusesAmbiguousAndLinkedInputs() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let restore = root.appendingPathComponent("iPhone_old_Restore")
        try FileManager.default.createSymbolicLink(atPath: restore.path, withDestinationPath: "missing")
        #expect(throws: (any Error).self) {
            try VPhoneNativeFirmwarePreparer.existingRestore(in: root, allowPreservation: true)
        }
        try FileManager.default.removeItem(at: restore)
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("iPhone_other_Restore"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try VPhoneNativeFirmwarePreparer.existingRestore(in: root, allowPreservation: true)
        }
    }

    @Test func publicationFailureRollsBackPreviousTree() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent("iPhone_old_Restore")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: previous.appendingPathComponent("marker"))
        let state = try VPhoneNativeFirmwarePreparer.existingRestore(in: root, allowPreservation: true)
        #expect(throws: (any Error).self) {
            try VPhoneNativeFirmwarePreparer.publish(root.appendingPathComponent("missing-staging"),
                to: previous, previous: state, bundle: root)
        }
        #expect(try Data(contentsOf: previous.appendingPathComponent("marker")) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [previous.lastPathComponent])
    }

    @Test func mergesWithoutMutatingSourcesAndRefusesRerun() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = try archive(root, cloud: false), cloud = try archive(root, cloud: true)
        let phoneBytes = try Data(contentsOf: phone), cloudBytes = try Data(contentsOf: cloud)
        let vm = root.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        let result = try VPhoneNativeFirmwarePreparer.prepare(iPhone: phone, cloudOS: cloud, bundle: vm, generateManifest: { phone, _ in
            try Data("generated".utf8).write(to: phone.appendingPathComponent("BuildManifest.plist"))
        })
        #expect(result.lastPathComponent == "iPhone17,3_26.1_23B85_Restore")
        #expect(try String(contentsOf: result.appendingPathComponent("kernelcache.test"), encoding: .utf8) == "cloud")
        #expect(try String(contentsOf: result.appendingPathComponent("shared.dmg"), encoding: .utf8) == "phone")
        #expect(try String(contentsOf: result.appendingPathComponent("Firmware/shared.dmg.trustcache"), encoding: .utf8) == "phone")
        #expect(try String(contentsOf: result.appendingPathComponent("BuildManifest.plist"), encoding: .utf8) == "generated")
        #expect(try Data(contentsOf: phone) == phoneBytes)
        #expect(try Data(contentsOf: cloud) == cloudBytes)
        #expect(throws: (any Error).self) {
            _ = try VPhoneNativeFirmwarePreparer.prepare(iPhone: phone, cloudOS: cloud, bundle: vm)
        }
        #expect(!VPhoneVMLockProbe.isLockHeld(directory: vm))
    }

    @Test func manifestFailureCleansStagingAndPublishesNothing() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = try archive(root, cloud: false), cloud = try archive(root, cloud: true)
        let vm = root.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try VPhoneNativeFirmwarePreparer.prepare(iPhone: phone, cloudOS: cloud, bundle: vm, generateManifest: { _, _ in
                throw CocoaError(.fileReadCorruptFile)
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: vm.path) == [".vphone-runtime.json"])
    }

    @Test func concurrentDestinationSurvivesAndInputCancellationCleansUp() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = try archive(root, cloud: false), cloud = try archive(root, cloud: true)
        let vm = root.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        #expect(throws: CancellationError.self) {
            _ = try VPhoneNativeFirmwarePreparer.prepare(iPhone: phone, cloudOS: cloud, bundle: vm, isCancelled: { true })
        }
        let competing = vm.appendingPathComponent("iPhone17,3_26.1_23B85_Restore")
        #expect(throws: (any Error).self) {
            _ = try VPhoneNativeFirmwarePreparer.prepare(iPhone: phone, cloudOS: cloud, bundle: vm, generateManifest: { _, _ in
                try Data("other owner".utf8).write(to: competing)
            })
        }
        #expect(try Data(contentsOf: competing) == Data("other owner".utf8))
    }

    @Test func rejectsArchiveLinksAndExistingDanglingRestore() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: files.appendingPathComponent("BuildManifest.plist").path, withDestinationPath: "/etc/passwd")
        let input = root.appendingPathComponent("links.ipsw")
        try VPhoneArchiveWriter.create(archive: input, from: files)
        #expect(throws: (any Error).self) { try VPhoneNativeFirmwarePreparer.validateArchive(input) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("old_Restore").path, withDestinationPath: "missing")
        #expect(throws: (any Error).self) { try VPhoneNativeFirmwarePreparer.rejectExistingRestore(in: root) }
    }

    @Test func heldVMLockRejectsBeforeOpeningInputs() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = try VPhoneVMLock(directory: root, operation: "boot")
        _ = withExtendedLifetime(lock) {
            #expect(throws: (any Error).self) {
                _ = try VPhoneNativeFirmwarePreparer.prepare(iPhone: root, cloudOS: root, bundle: root)
            }
        }
    }
}

/// Real native prepare dispatch and read-only verifier, with a synthetic ROM
/// and a deliberate stop before any firmware patch or VM operation.
private final class NativePrepareCheckpointStages: VPhoneCreateStageExecutor, VPhoneCreateStageVerifier, VPhoneCreateStateProber {
    let live: VPhoneCreateLiveStages
    var prepareRuns = 0
    var version: String { live.version }

    init(bundle: URL) {
        let orchestrator = VPhoneCreateOrchestrator(library: VPhoneLibrary(root: bundle.deletingLastPathComponent()),
            resources: VPhoneResources(base: bundle.appendingPathComponent("no-script-resources")),
            selfExecutable: URL(fileURLWithPath: "/usr/bin/false"))
        live = VPhoneCreateLiveStages(orchestrator: orchestrator,
            runtime: .init(sudoEnvExtras: [:], rootPopup: false, interactive: false, verbosity: .quiet, keepArtifacts: true))
    }

    func execute(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) throws -> [String: String] {
        guard stage == .prepare else { throw CocoaError(.featureUnsupported) }
        prepareRuns += 1
        try Data("synthetic ROM".utf8).write(to: context.bundleURL.appendingPathComponent("AVPBooter.vresearch1.bin"))
        try live.orchestrator.runFWPrepare(iphoneSource: context.iphoneSource, cloudosSource: context.cloudosSource,
            isLess: false, keepArtifacts: true, bundleURL: context.bundleURL, verbosity: .quiet,
            backend: context.options.effectivePrepareBackend,
            preserveExistingRestore: !context.checkpoint.record(.prepare).history.isEmpty)
        return ["fw_prepare_exit": "0", "prepare_backend": context.options.effectivePrepareBackend.rawValue]
    }

    func artifactsRewrittenOnRerun(_ stage: VPhoneCreateStage) -> Set<String> { live.artifactsRewrittenOnRerun(stage) }
    func removeArtifact(_ artifact: VPhoneCreateArtifactRecord, context: VPhoneCreateStageContext) -> Bool { false }
    func verify(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext, evidence: [String: String]) -> VPhoneCreateVerification {
        live.verify(stage, context: context, evidence: evidence)
    }
    func probe(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) -> VPhoneCreateProbeResult { .idle(evidence: "synthetic test") }
}

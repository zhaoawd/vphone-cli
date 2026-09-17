import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

// D4: the production verifier and live-state prober, exercised with temporary
// bundles and injected process/lock/device observations. Nothing here boots,
// restores, mounts or runs sudo.

private struct Workspace {
    let bundle: URL

    init() throws {
        bundle = FileManager.default.temporaryDirectory.appendingPathComponent("d4-live-" + UUID().uuidString)
            .appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

    func context(variant: String = "jb") -> VPhoneCreateStageContext {
        let options = VPhoneCreateEffectiveOptions(
            variant: variant, iphoneSource: nil, cloudosSource: nil, spoofBuild: nil, forceDscMaxSlide: false,
            enableFrida: false, cpuCount: 8, memoryMb: 8192, diskSizeGb: 64)
        let checkpoint = VPhoneCreateCheckpoint(
            identity: .init(name: "vm", path: bundle.path, directoryId: "1:2"), options: options,
            tool: .init(executableSha256: nil, stageContractVersion: 1), now: Date())
        return VPhoneCreateStageContext(
            bundleURL: bundle, bundleName: "vm", options: options, iphoneSource: nil, cloudosSource: nil,
            checkpoint: checkpoint)
    }

    func stages(lockHeld: Bool = false) -> VPhoneCreateLiveStages {
        let orchestrator = VPhoneCreateOrchestrator(
            library: VPhoneLibrary(root: bundle.deletingLastPathComponent()),
            resources: VPhoneResources(base: bundle), selfExecutable: URL(fileURLWithPath: "/usr/bin/false"))
        var stages = VPhoneCreateLiveStages(
            orchestrator: orchestrator,
            runtime: .init(sudoEnvExtras: [:], rootPopup: false, interactive: false, verbosity: .quiet, keepArtifacts: false))
        stages.lockHeld = { _ in lockHeld }
        return stages
    }

    func writePlist(_ object: [String: Any], _ relative: String) throws {
        let url = bundle.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url)
    }
}

private func isVerified(_ result: VPhoneCreateVerification) -> Bool {
    if case .verified = result { return true }
    return false
}

private func unverifiedReason(_ result: VPhoneCreateVerification) -> String? {
    if case let .unverified(reason, _, _) = result { return reason }
    return nil
}

private func isRejected(_ result: VPhoneCreateVerification) -> Bool {
    if case .rejected = result { return true }
    return false
}

struct CreateLiveStagesTests {
    // MARK: Verifier

    @Test func jbFinalizeIsNeverVerifiedFromAPrintedHint() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let result = w.stages().verify(.jbFinalize, context: w.context(), evidence: ["hint_printed": "true"])
        #expect(unverifiedReason(result)?.contains("vphone_jb_setup") == true)
    }

    @Test func firstBootPromptTimeoutIsUnverified() throws {
        let w = try Workspace(); defer { w.cleanup() }
        try Data("disk".utf8).write(to: w.bundle.appendingPathComponent("Disk.img"))
        let stages = w.stages()
        #expect(unverifiedReason(stages.verify(.firstBoot, context: w.context(), evidence: ["prompt": "timed_out", "boot_exit": "0"])) != nil)
        #expect(isVerified(stages.verify(.firstBoot, context: w.context(), evidence: ["prompt": "matched", "boot_exit": "0"])))
        #expect(isRejected(stages.verify(.firstBoot, context: w.context(), evidence: [:])))
        #expect(isRejected(w.stages(lockHeld: true).verify(.firstBoot, context: w.context(), evidence: ["prompt": "matched", "boot_exit": "0"])))
    }

    @Test func lessVerificationBootIsUnverified() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let result = w.stages().verify(.verification, context: w.context(variant: "less"), evidence: ["less_boot_exit": "0"])
        #expect(unverifiedReason(result) != nil)
        #expect(isVerified(w.stages().verify(.verification, context: w.context(), evidence: ["boot_analysis": "prompt_detected"])))
    }

    @Test func patchRequiresOneCommittedTransactionForTheVariant() throws {
        let w = try Workspace(); defer { w.cleanup() }
        try Data("rom".utf8).write(to: w.bundle.appendingPathComponent("AVPBooter.vresearch1.bin"))
        let archive = w.bundle.appendingPathComponent(".firmware-history/abc")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let journal = archive.appendingPathComponent("journal.json")
        let evidence = ["firmware_transaction_archives": "abc", "patch_records": "10"]
        let stages = w.stages()

        try Data(#"{"phase":"committed","options":{"variant":"jb"}}"#.utf8).write(to: journal)
        #expect(isVerified(stages.verify(.patch, context: w.context(), evidence: evidence)))
        #expect(isRejected(stages.verify(.patch, context: w.context(variant: "dev"), evidence: evidence)))
        #expect(isRejected(stages.verify(.patch, context: w.context(), evidence: ["firmware_transaction_archives": ""])))

        try Data(#"{"phase":"publishing","options":{"variant":"jb"}}"#.utf8).write(to: journal)
        #expect(isRejected(stages.verify(.patch, context: w.context(), evidence: evidence)))

        try Data(#"{"phase":"committed","options":{"variant":"jb"}}"#.utf8).write(to: journal)
        try FileManager.default.createDirectory(at: w.bundle.appendingPathComponent(".firmware-transaction"), withIntermediateDirectories: false)
        #expect(isRejected(stages.verify(.patch, context: w.context(), evidence: evidence)))
    }

    @Test func prepareRequiresExactlyOneRestoreTreeWithVersions() throws {
        let w = try Workspace(); defer { w.cleanup() }
        try Data("rom".utf8).write(to: w.bundle.appendingPathComponent("AVPBooter.vresearch1.bin"))
        let stages = w.stages()
        let evidence = ["fw_prepare_exit": "0"]
        #expect(isRejected(stages.verify(.prepare, context: w.context(), evidence: evidence)))
        try w.writePlist(["ProductVersion": "26.1", "ProductBuildVersion": "23B85"], "iPhone17,3_26.1_23B85_Restore/iPhone-BuildManifest.plist")
        #expect(isRejected(stages.verify(.prepare, context: w.context(), evidence: evidence)))
        try w.writePlist(["ProductVersion": "26.1", "ProductBuildVersion": "23B85"], "iPhone17,3_26.1_23B85_Restore/BuildManifest.plist")
        guard case let .verified(artifacts, versions) = stages.verify(.prepare, context: w.context(), evidence: evidence) else {
            Issue.record("prepare not verified")
            return
        }
        #expect(versions["ios_build"] == "23B85")
        #expect(artifacts.first { $0.name == "restore_tree" }?.retainUntil == [.patch, .restore, .cfw, .firstBoot, .verification])
        try FileManager.default.createDirectory(at: w.bundle.appendingPathComponent("iPhone17,3_18.5_22F76_Restore"), withIntermediateDirectories: false)
        #expect(isRejected(stages.verify(.prepare, context: w.context(), evidence: evidence)))
    }

    @Test func rerunRewriteDeclarations() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let stages = w.stages()
        #expect(stages.artifactsRewrittenOnRerun(.patch).isEmpty)
        #expect(stages.artifactsRewrittenOnRerun(.prepare) == ["restore_tree", "avpbooter"])
        #expect(stages.artifactsRewrittenOnRerun(.cfw).contains("disk_image"))
    }

    // MARK: Status view

    @Test func statusReportIsReadOnlyAndShowsStagesAndLiveFacts() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let missing = VPhoneCreateStatusReport.make(bundleURL: w.bundle)
        #expect(missing.checkpointError?.contains("no create checkpoint") == true)

        let store = try VPhoneCreateCheckpointStore.initialize(bundleURL: w.bundle)
        let dirID = try { () throws -> String in
            var info = stat()
            guard lstat(w.bundle.path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
            return "\(info.st_dev):\(info.st_ino)"
        }()
        let context = w.context(variant: "regular")
        let checkpoint = VPhoneCreateCheckpoint(
            identity: .init(name: "vm", path: w.bundle.path, directoryId: dirID), options: context.options,
            tool: .init(executableSha256: nil, stageContractVersion: 1), now: Date())
        try store.commit(checkpoint)
        let bytes = try Data(contentsOf: store.fileURL)

        let report = VPhoneCreateStatusReport.make(bundleURL: w.bundle)
        #expect(report.checkpointError == nil)
        #expect(report.overallStatus == .incomplete)
        #expect(report.nextStage == .prepare)
        #expect(report.live.createRunInProgress)  // `store` still holds the run lock
        #expect(report.text.contains("jb_finalize"))
        #expect(report.text.contains("not_applicable"))
        let json = try JSONSerialization.jsonObject(with: VPhoneCreateJSON.encoder.encode(report)) as? [String: Any]
        #expect(json?["overall_status"] as? String == "incomplete")
        #expect((json?["live"] as? [String: Any])?["bundle_lock_held"] as? Bool == false)
        #expect(try Data(contentsOf: store.fileURL) == bytes)
        withExtendedLifetime(store) {}
    }

    // MARK: Prober

    private func prober(
        lockHeld: Bool = false, ps: String = "", reachable: Bool = false, images: [String] = []
    ) -> (VPhoneCreateLiveProber, Box) {
        let box = Box()
        let prober = VPhoneCreateLiveProber(
            lockHeld: { _ in lockHeld },
            processList: { ps },
            recoveryReachable: { ecid in box.probedECIDs.append(ecid); return reachable },
            attachedImages: { images })
        return (prober, box)
    }

    final class Box: @unchecked Sendable { var probedECIDs: [String] = [] }

    private func writeIdentity(_ w: Workspace) throws {
        try Data("UDID=0000FE01-0011223344556677\nECID=0x0011223344556677\n".utf8)
            .write(to: w.bundle.appendingPathComponent("udid-prediction.txt"))
    }

    private func isBusy(_ result: VPhoneCreateProbeResult) -> Bool {
        if case .busy = result { return true }
        return false
    }

    @Test func restoreReprobeRefusesWhileBundleLockIsHeld() throws {
        let w = try Workspace(); defer { w.cleanup() }
        try writeIdentity(w)
        #expect(isBusy(prober(lockHeld: true).0.probe(.restore, context: w.context())))
    }

    @Test func restoreReprobeRefusesWhileBridgeProcessRuns() throws {
        let w = try Workspace(); defer { w.cleanup() }
        try writeIdentity(w)
        let ps = "4242 /venv/bin/python3 /repo/scripts/pymobiledevice3_bridge.py restore-update --vm-dir . --udid X --ecid 0x0011223344556677\n"
        let result = prober(ps: ps).0.probe(.restore, context: w.context())
        guard case let .busy(detail, _) = result else { Issue.record("expected busy"); return }
        #expect(detail.contains("4242"))
    }

    @Test func restoreReprobeIgnoresOtherDevices() throws {
        let w = try Workspace(); defer { w.cleanup() }
        try writeIdentity(w)
        let ps = "4242 python3 pymobiledevice3_bridge.py restore-update --ecid 0x00000000DEADBEEF\n"
        let (p, box) = prober(ps: ps)
        guard case let .idle(evidence) = p.probe(.restore, context: w.context()) else { Issue.record("expected idle"); return }
        #expect(evidence.contains("no DFU/recovery endpoint for 0x0011223344556677"))
        #expect(box.probedECIDs == ["0x0011223344556677"])
    }

    @Test func restoreReprobeRefusesWhileDeviceEndpointAnswers() throws {
        let w = try Workspace(); defer { w.cleanup() }
        try writeIdentity(w)
        #expect(isBusy(prober(reachable: true).0.probe(.restore, context: w.context())))
    }

    @Test func reprobeRefusesWhileBootProcessForBundleRuns() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let config = w.bundle.appendingPathComponent("config.plist").path
        let ps = "777 /Applications/vphone-cli.app/Contents/MacOS/vphone-cli --config \(config) --dfu\n"
        #expect(isBusy(prober(ps: ps).0.probe(.firstBoot, context: w.context())))
    }

    @Test func cfwReprobeRefusesWhileBundleImageIsAttached() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let inside = w.bundle.appendingPathComponent(".cfw_mount.abc/SystemOS.dmg").path
        #expect(isBusy(prober(images: [inside]).0.probe(.cfw, context: w.context())))
        #expect(!isBusy(prober(images: ["/tmp/other.dmg"]).0.probe(.cfw, context: w.context())))
    }
}

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
        stages(lockHeld: { _ in lockHeld })
    }

    func stages(lockHeld: @escaping (URL) -> Bool, timeout: TimeInterval = 0.2) -> VPhoneCreateLiveStages {
        let orchestrator = VPhoneCreateOrchestrator(
            library: VPhoneLibrary(root: bundle.deletingLastPathComponent()),
            resources: VPhoneResources(base: bundle), selfExecutable: URL(fileURLWithPath: "/usr/bin/false"))
        var stages = VPhoneCreateLiveStages(
            orchestrator: orchestrator,
            runtime: .init(sudoEnvExtras: [:], rootPopup: false, interactive: false, verbosity: .quiet, keepArtifacts: false))
        stages.lockHeld = lockHeld
        stages.lockReleaseTimeout = timeout
        stages.lockPollInterval = 0.02
        return stages
    }

    var checkpointURL: URL { bundle.appendingPathComponent(".create-checkpoint/checkpoint.json") }

    /// Writes a fresh checkpoint for this bundle and returns its bytes. The
    /// store (and its run lock) is released before returning.
    func writeCheckpoint() throws -> Data {
        var info = stat()
        guard lstat(bundle.path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        let options = context(variant: "regular").options
        let checkpoint = VPhoneCreateCheckpoint(
            identity: .init(name: "vm", path: bundle.standardizedFileURL.path, directoryId: "\(info.st_dev):\(info.st_ino)"),
            options: options, tool: .init(executableSha256: nil, stageContractVersion: VPhoneCreateCheckpoint.stageContractVersion),
            now: Date())
        try withExtendedLifetime(VPhoneCreateCheckpointStore.initialize(bundleURL: bundle)) { try $0.commit(checkpoint) }
        return try Data(contentsOf: checkpointURL)
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

/// A separate process holding an exclusive flock on a directory until stopped.
private final class LockHolder: @unchecked Sendable {
    let process = Process()

    init(path: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-c",
            "import os,fcntl,sys,time; f=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); time.sleep(60)",
            path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        _ = pipe.fileHandleForReading.availableData
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
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
        #expect(report.overallStatus == "running")  // `store` holds the run lock through its own descriptor
        #expect(report.checkpointOverallStatus == .incomplete)
        #expect(report.nextStage == .prepare)
        #expect(report.live.createRunInProgress)  // `store` still holds the run lock
        #expect(report.text.contains("jb_finalize"))
        #expect(report.text.contains("not_applicable"))
        let json = try JSONSerialization.jsonObject(with: VPhoneCreateJSON.encoder.encode(report)) as? [String: Any]
        #expect(json?["overall_status"] as? String == "running")
        #expect(json?["checkpoint_overall_status"] as? String == "incomplete")
        #expect((json?["live"] as? [String: Any])?["bundle_lock_held"] as? Bool == false)
        #expect(try Data(contentsOf: store.fileURL) == bytes)
        withExtendedLifetime(store) {}
    }

    @Test func statusViewShowsRunningOnlyWhileAnotherProcessHoldsTheRunLock() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let bytes = try w.writeCheckpoint()
        let child = try LockHolder(path: w.bundle.appendingPathComponent(".create-checkpoint").path)
        defer { child.stop() }

        let running = VPhoneCreateStatusReport.make(bundleURL: w.bundle)
        #expect(running.live.createRunInProgress)
        #expect(running.overallStatus == "running")
        #expect(running.checkpointOverallStatus == .incomplete)
        #expect(running.text.contains("overall:  running"))

        child.stop()
        let idle = VPhoneCreateStatusReport.make(bundleURL: w.bundle)
        #expect(!idle.live.createRunInProgress)
        #expect(idle.overallStatus == "incomplete")
        #expect(idle.checkpointOverallStatus == .incomplete)
        #expect(try Data(contentsOf: w.checkpointURL) == bytes)
    }

    // MARK: Lock release after a stage

    @Test func verifierAcceptsWhenTheLockIsReleasedWithinTheBound() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let released = Date().addingTimeInterval(0.3)
        let stages = w.stages(lockHeld: { _ in Date() < released }, timeout: 5)
        #expect(isVerified(stages.verify(.verification, context: w.context(), evidence: ["boot_analysis": "prompt_detected"])))
        #expect(Date() >= released)
        #expect(isVerified(stages.verify(.firstBoot, context: w.context(), evidence: ["prompt": "matched", "boot_exit": "0"])))
    }

    @Test func verifierRejectsAfterTheBoundWhenTheLockIsNeverReleased() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let stages = w.stages(lockHeld: { _ in true }, timeout: 0.3)
        let cases: [(VPhoneCreateStage, [String: String])] = [
            (.restore, ["restore_update_exit": "0", "ecid": "0x0011223344556677"]),
            (.cfw, ["cfw_install_exit": "0"]),
            (.firstBoot, ["prompt": "matched", "boot_exit": "0"]),
            (.verification, ["boot_analysis": "prompt_detected"]),
        ]
        for (stage, evidence) in cases {
            let started = Date()
            guard case let .rejected(reason) = stages.verify(stage, context: w.context(), evidence: evidence) else {
                Issue.record("\(stage.rawValue) not rejected")
                continue
            }
            let elapsed = Date().timeIntervalSince(started)
            #expect(reason.contains("bundle lock still held 0.30s"))
            #expect(elapsed >= 0.3 && elapsed < 5)
        }
    }

    @Test func verifierWaitsForARealBundleLockHolderToRelease() throws {
        let w = try Workspace(); defer { w.cleanup() }
        final class Holder: @unchecked Sendable { var lock: VPhoneVMLock? }
        let holder = Holder()
        holder.lock = try VPhoneVMLock(directory: w.bundle, operation: VPhoneVMOperation.dfu)
        var stages = w.stages()
        stages.lockHeld = { VPhoneVMLockProbe.isLockHeld(directory: $0) }
        stages.lockReleaseTimeout = 0.2
        #expect(isRejected(stages.verify(.verification, context: w.context(), evidence: ["boot_analysis": "prompt_detected"])))

        stages.lockReleaseTimeout = 10
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { holder.lock = nil }
        #expect(isVerified(stages.verify(.verification, context: w.context(), evidence: ["boot_analysis": "prompt_detected"])))
    }

    // MARK: Stage children

    final class FakeChild: @unchecked Sendable {
        var stops = 0
        var exitAfter: Date?
        func stop() { stops += 1; if exitAfter == nil { exitAfter = Date().addingTimeInterval(0.2) } }
        func awaitExit(_ timeout: TimeInterval, exits: Bool) -> Bool {
            guard exits, let exitAfter else { Thread.sleep(forTimeInterval: timeout); return false }
            let wait = exitAfter.timeIntervalSinceNow
            guard wait <= timeout else { Thread.sleep(forTimeInterval: timeout); return false }
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            return true
        }
    }

    struct BodyFailure: Error {}

    @Test func stageReturnsOnlyAfterItsChildExited() throws {
        let child = FakeChild()
        let value = try VPhoneCreateOrchestrator.withStoppedChild(
            "fake child", timeout: 5, stop: child.stop, awaitExit: { child.awaitExit($0, exits: true) }) { 7 }
        #expect(value == 7)
        #expect(child.stops == 1)
        #expect(child.exitAfter.map { Date() >= $0 } == true)
    }

    @Test func stuckChildFailsTheStageAfterTheBound() throws {
        let child = FakeChild()
        let started = Date()
        #expect { try VPhoneCreateOrchestrator.withStoppedChild(
            "fake child", timeout: 0.2, stop: child.stop, awaitExit: { child.awaitExit($0, exits: false) }) { 7 }
        } throws: { error in
            guard case VPhoneCreateError.childDidNotExit(label: "fake child", timeout: 0.2) = error else { return false }
            return true
        }
        #expect(Date().timeIntervalSince(started) < 5)

        // A failing stage keeps its own error; the stuck child is only reported.
        let other = FakeChild()
        #expect(throws: BodyFailure.self) {
            try VPhoneCreateOrchestrator.withStoppedChild(
                "fake child", timeout: 0.2, stop: other.stop, awaitExit: { other.awaitExit($0, exits: false) }
            ) { () throws -> Int in throw BodyFailure() }
        }
        #expect(other.stops == 1)
    }

    @Test func realChildHoldingTheBundleLockHasReleasedItWhenTheStageReturns() throws {
        let w = try Workspace(); defer { w.cleanup() }
        // Holds the bundle flock and needs 0.5 s to exit after SIGINT.
        let script = "import fcntl,os,signal,sys,time\n"
            + "fd=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(fd,fcntl.LOCK_EX)\n"
            + "signal.signal(signal.SIGINT, lambda *a: (time.sleep(0.5), os._exit(0)))\n"
            + "print('ready',flush=True)\n"
            + "while True: time.sleep(0.05)\n"
        let child = VPhoneManagedProcess(URL(fileURLWithPath: "/usr/bin/env"), ["python3", "-c", script, w.bundle.path], echo: false)
        try child.start()
        guard case .matched = child.waitForOutput(matching: "ready", timeout: 10) else {
            child.terminate()
            Issue.record("lock holder did not start")
            return
        }
        #expect(VPhoneVMLockProbe.isLockHeld(directory: w.bundle))
        try VPhoneCreateOrchestrator.withStoppedChild(child, "python lock holder", timeout: 10) {}
        #expect(!VPhoneVMLockProbe.isLockHeld(directory: w.bundle))
        #expect(VPhoneCreateOrchestrator.awaitExit(child, timeout: 0))
    }

    // MARK: Refusal hints

    @Test func busyResumeLeadsWithStopGuidanceAndKeepsTheCheckpoint() throws {
        let w = try Workspace(); defer { w.cleanup() }
        let bytes = try w.writeCheckpoint()
        let vm = try VPhoneVMLock(directory: w.bundle, operation: VPhoneVMOperation.dfu)
        let (prober, _) = prober(lockHeld: true)
        let stages = w.stages()
        let runner = VPhoneCreateRunner(executor: stages, verifier: stages, prober: prober, log: { _ in })
        var thrown: Error?
        do { try runner.resume(bundleURL: w.bundle) } catch { thrown = error }
        withExtendedLifetime(vm) {}
        guard let error = thrown, case VPhoneCreateRunError.bundleBusy = error else {
            Issue.record("expected bundleBusy, got \(String(describing: thrown))")
            return
        }
        #expect(try Data(contentsOf: w.checkpointURL) == bytes)

        let lines = VPhoneCreateOrchestrator.recoveryHintLines(
            name: "vm", bundleURL: w.bundle, error: error, holder: { _ in "pid 42 running operation \"dfu\"" })
        #expect(lines.first?.contains("refused: the bundle is in use") == true)
        #expect(lines.first?.contains("checkpoint was not changed (overall: incomplete)") == true)
        #expect(!lines.contains { $0.contains("recovery required") })
        #expect(!lines.contains { $0.hasPrefix("    Resume:") })
        let action = lines.firstIndex { $0.contains("action: wait") && $0.contains("vm stop vm") }
        let resume = lines.firstIndex { $0.contains("vphone-cli vm create --resume vm") }
        #expect(action != nil && resume != nil && action! < resume!)
        #expect(lines.contains("    holder (runtime record): pid 42 running operation \"dfu\""))
        #expect(try Data(contentsOf: w.checkpointURL) == bytes)
    }

    @Test func unrecordedLiveStateAndRunInProgressRefusalsPrintGuidanceFirst() throws {
        let w = try Workspace(); defer { w.cleanup() }
        _ = try w.writeCheckpoint()
        // The requirement has no public initializer outside VPhoneCore; decode it as stored.
        let live = VPhoneCreateRunError.recoveryRequired(try VPhoneCreateJSON.decoder.decode(
            VPhoneCreateRecoveryRequirement.self,
            from: Data(#"{"kind":"live_state","stage":"restore","detail":"restore bridge still running","action":"stop it, then resume"}"#.utf8)))
        let liveLines = VPhoneCreateOrchestrator.recoveryHintLines(name: "vm", bundleURL: w.bundle, error: live)
        #expect(liveLines.first?.contains("recovery required (live_state, stage restore)") == true)
        let actionIndex = liveLines.firstIndex { $0.contains("action: stop it, then resume") }
        let resumeIndex = liveLines.firstIndex { $0.hasPrefix("    Resume:") }
        #expect(actionIndex != nil && resumeIndex != nil && actionIndex! < resumeIndex!)

        let busy = VPhoneCreateOrchestrator.recoveryHintLines(
            name: "vm", bundleURL: w.bundle, error: VPhoneCreateRunError.runInProgress(w.bundle.path))
        #expect(busy.first?.contains("another vm create or resume") == true)
        #expect(busy.dropFirst().first?.contains("wait for that run to exit") == true)
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

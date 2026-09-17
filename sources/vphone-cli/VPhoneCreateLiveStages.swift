import Foundation
import VPhoneCore

// MARK: - Artifact names

enum VPhoneCreateArtifact {
    static let restoreTree = "restore_tree"
    static let bootROM = "avpbooter"
    static let config = "config"
    static let diskImage = "disk_image"
    static let restoreInfo = "restore_info"

    /// Consumers of the restore tree (patch, restore, cfw) plus the stages whose
    /// failure may require a new restore (first_boot, verification).
    static let restoreTreeRetainedUntil: [VPhoneCreateStage] = [.patch, .restore, .cfw, .firstBoot, .verification]
}

// MARK: - VPhoneCreateLiveStages

/// Production executor and verifier for `vm create`.
///
/// The executor drives the real pipeline through `VPhoneCreateOrchestrator`.
/// The verifier only reads files, locks and recorded evidence; it never boots,
/// restores or mounts. Stages without host-side evidence report `unverified`.
struct VPhoneCreateLiveStages: VPhoneCreateStageExecutor, VPhoneCreateStageVerifier {
    let orchestrator: VPhoneCreateOrchestrator
    let runtime: VPhoneCreateRuntime
    var lockHeld: (URL) -> Bool = { VPhoneVMLockProbe.isLockHeld(directory: $0) }
    /// How long the verifier waits for a stage's children to release the
    /// bundle lock before rejecting. A child releases the lock when it exits,
    /// which can trail the executor's return (real run, 2026-09-17: a DFU
    /// child killed after restore still held the lock when the verifier ran).
    var lockReleaseTimeout: TimeInterval = VPhoneCreateCheckpointStore.bundleLockRetryTimeout
    var lockPollInterval: TimeInterval = 0.1

    let version = "vm-create-live-verifier-1"

    // MARK: Executor

    func execute(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) throws -> [String: String] {
        let bundleURL = context.bundleURL
        let options = context.options
        let v = runtime.verbosity
        let isLess = options.variant == "less"
        guard let variant = PatchFirmwareCLI.VariantOption(rawValue: options.variant) else {
            throw VPhoneCreateError.unknownVariant(options.variant)
        }
        switch stage {
        case .prepare:
            try orchestrator.refreshBootROM(bundleURL: bundleURL)
            try orchestrator.runFWPrepare(
                iphoneSource: context.iphoneSource, cloudosSource: context.cloudosSource, isLess: isLess,
                keepArtifacts: runtime.keepArtifacts, bundleURL: bundleURL, verbosity: v)
            return ["fw_prepare_exit": "0"]
        case .patch:
            let before = Self.historyEntries(bundleURL)
            let count = try orchestrator.runFWPatch(
                variant: variant, isLess: isLess, enableFrida: options.enableFrida, bundleURL: bundleURL, verbosity: v)
            let new = Self.historyEntries(bundleURL).subtracting(before).sorted()
            return ["patch_records": "\(count)", "firmware_transaction_archives": new.joined(separator: ",")]
        case .restore:
            return try orchestrator.runRestorePhase(bundleURL: bundleURL, verbosity: v)
        case .cfw:
            print("[*] Waiting 5s for cleanup before CFW install...")
            Thread.sleep(forTimeInterval: 5)
            try orchestrator.runCFWInstall(options: options, runtime: runtime, bundleURL: bundleURL)
            return ["cfw_install_exit": "0"]
        case .firstBoot:
            return try orchestrator.runFirstBoot(
                isLess: isLess, interactive: runtime.interactive, bundleURL: bundleURL, verbosity: v)
        case .jbFinalize:
            print("[*] JB finalization will run automatically on first normal boot")
            print("    via /cores/vphone_jb_setup.sh (LaunchDaemon).")
            print("    Monitor progress via vphoned file browser: /var/log/vphone_jb_setup.log")
            return ["hint_printed": "true"]
        case .verification:
            if isLess {
                try orchestrator.startVMForeground(bundleURL: bundleURL, verbosity: v)
                return ["less_boot_exit": "0"]
            }
            try orchestrator.runBootAnalysis(bundleURL: bundleURL, verbosity: v)
            return ["boot_analysis": "prompt_detected"]
        }
    }

    func artifactsRewrittenOnRerun(_ stage: VPhoneCreateStage) -> Set<String> {
        switch stage {
        // fw prepare replaces the restore tree; refreshBootROM replaces the ROM.
        case .prepare: [VPhoneCreateArtifact.restoreTree, VPhoneCreateArtifact.bootROM]
        // A restore erases the disk and a DFU boot writes the machine identifier.
        case .restore: [VPhoneCreateArtifact.diskImage, VPhoneCreateArtifact.config, VPhoneCreateArtifact.restoreInfo]
        // D3: CFW installation can be repeated on the same restored disk.
        case .cfw: [VPhoneCreateArtifact.diskImage, VPhoneCreateArtifact.restoreInfo]
        case .firstBoot, .verification: [VPhoneCreateArtifact.diskImage]
        // Patch publishes only through a C4 transaction; a changed tree is refused.
        case .patch, .jbFinalize: []
        }
    }

    func removeArtifact(_ artifact: VPhoneCreateArtifactRecord, context: VPhoneCreateStageContext) -> Bool {
        guard artifact.name == VPhoneCreateArtifact.restoreTree, !runtime.keepArtifacts,
              let bundle = try? VPhoneBundle.load(at: context.bundleURL),
              let removed = VPhoneRestoreInfo.removeBuiltFirmwareIfIdle(fromBundle: bundle)
        else { return false }
        print("[+] Removed built firmware \(removed)/ to save space (--keep-artifacts to keep)")
        return true
    }

    // MARK: Verifier

    func verify(
        _ stage: VPhoneCreateStage, context: VPhoneCreateStageContext, evidence: [String: String]
    ) -> VPhoneCreateVerification {
        let bundleURL = context.bundleURL
        let treeRemoved = context.checkpoint.artifact(VPhoneCreateArtifact.restoreTree)?.availability == .removed
        switch stage {
        case .prepare:
            guard evidence["fw_prepare_exit"] == "0" else { return .rejected("no fw prepare exit status") }
            if treeRemoved { return .verified(artifacts: [], evidence: ["restore_tree": "removed by cleanup"]) }
            guard let tree = Self.restoreTree(bundleURL) else {
                return .rejected("expected exactly one iPhone*_Restore directory in the bundle")
            }
            guard let versions = Self.manifestVersions(tree) else {
                return .rejected("\(tree.lastPathComponent) lacks readable BuildManifest.plist / iPhone-BuildManifest.plist versions")
            }
            return .verified(artifacts: [
                .init(name: VPhoneCreateArtifact.restoreTree, relativePath: tree.lastPathComponent, kind: .treeMetadata,
                      retainUntil: VPhoneCreateArtifact.restoreTreeRetainedUntil),
                .init(name: VPhoneCreateArtifact.bootROM, relativePath: "AVPBooter.vresearch1.bin", kind: .sha256File),
            ], evidence: versions)

        case .patch:
            if Self.exists(bundleURL.appendingPathComponent(".firmware-transaction")) {
                return .rejected("firmware transaction is still pending")
            }
            let archives = (evidence["firmware_transaction_archives"] ?? "").split(separator: ",").map(String.init)
            guard archives.count == 1, let archive = archives.first else {
                return .rejected("expected exactly one new committed firmware transaction archive, found \(archives.count)")
            }
            let journal = bundleURL.appendingPathComponent(".firmware-history").appendingPathComponent(archive)
                .appendingPathComponent("journal.json")
            guard let data = try? Data(contentsOf: journal),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .rejected("firmware transaction journal \(archive) is unreadable") }
            guard object["phase"] as? String == "committed" else {
                return .rejected("firmware transaction \(archive) is not committed")
            }
            guard (object["options"] as? [String: String])?["variant"] == context.options.variant else {
                return .rejected("firmware transaction \(archive) was made for another variant")
            }
            var artifacts: [VPhoneCreateArtifactSpec] = []
            if !treeRemoved, let tree = Self.restoreTree(bundleURL) {
                artifacts.append(.init(
                    name: VPhoneCreateArtifact.restoreTree, relativePath: tree.lastPathComponent, kind: .treeMetadata,
                    retainUntil: VPhoneCreateArtifact.restoreTreeRetainedUntil))
            }
            artifacts.append(.init(name: VPhoneCreateArtifact.bootROM, relativePath: "AVPBooter.vresearch1.bin", kind: .sha256File))
            return .verified(artifacts: artifacts, evidence: ["firmware_transaction": archive])

        case .restore:
            guard evidence["restore_update_exit"] == "0", let ecid = evidence["ecid"] else {
                return .rejected("no restore-update exit status")
            }
            if !waitForLockRelease(bundleURL) { return .rejected(lockStillHeld("after restore (DFU child alive)")) }
            guard let identity = try? orchestrator.loadDeviceIdentity(bundleURL: bundleURL, wait: 0),
                  "0x\(identity.ecid)" == ecid
            else { return .rejected("udid-prediction.txt does not match the restored ECID \(ecid)") }
            guard let bundle = try? VPhoneBundle.load(at: bundleURL), !bundle.manifest.machineIdentifier.isEmpty else {
                return .rejected("config.plist has no machineIdentifier")
            }
            guard VPhoneRestoreInfo.load(fromBundle: bundle) != nil else {
                return .rejected("restored versions are not recorded and cannot be derived")
            }
            var artifacts = Self.diskArtifacts(bundleURL, includeRestoreInfo: true)
            artifacts.append(.init(name: VPhoneCreateArtifact.config, relativePath: "config.plist", kind: .sha256File))
            return .verified(artifacts: artifacts, evidence: [:])

        case .cfw:
            guard evidence["cfw_install_exit"] == "0" else { return .rejected("no CFW install exit status") }
            if !waitForLockRelease(bundleURL) { return .rejected(lockStillHeld("after CFW install")) }
            guard let bundle = try? VPhoneBundle.load(at: bundleURL),
                  VPhoneRestoreInfo.load(fromBundle: bundle)?.variant == context.options.variant
            else { return .rejected("restore-info.json does not record variant \(context.options.variant)") }
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: bundleURL.path)) ?? [])
                .filter { $0.hasPrefix(".cfw_mount.") }
            guard leftovers.isEmpty else { return .rejected("CFW mount directories remain: \(leftovers.joined(separator: ", "))") }
            return .verified(artifacts: Self.diskArtifacts(bundleURL, includeRestoreInfo: true), evidence: [:])

        case .firstBoot:
            guard evidence["boot_exit"] != nil else { return .rejected("no first-boot exit status") }
            if !waitForLockRelease(bundleURL) { return .rejected(lockStillHeld("after first boot")) }
            let artifacts = Self.diskArtifacts(bundleURL, includeRestoreInfo: false)
            switch evidence["prompt"] {
            case "matched", "operator_confirmed":
                return .verified(artifacts: artifacts, evidence: [:])
            default:
                return .unverified(
                    reason: "shell prompt was not detected within 60s; first-boot commands were sent without confirmation",
                    artifacts: artifacts, evidence: [:])
            }

        case .jbFinalize:
            return .unverified(
                reason: "JB finalization runs inside the guest on the first normal boot (/cores/vphone_jb_setup.sh); "
                    + "vm create has no host-side reader for /var/log/vphone_jb_setup.log",
                artifacts: [], evidence: [:])

        case .verification:
            if !waitForLockRelease(bundleURL) { return .rejected(lockStillHeld("after the verification boot")) }
            let artifacts = Self.diskArtifacts(bundleURL, includeRestoreInfo: false)
            if context.options.variant == "less" {
                guard evidence["less_boot_exit"] == "0" else { return .rejected("no less boot exit status") }
                return .unverified(
                    reason: "less boot has no success marker; its exit status after the operator quits is not boot evidence",
                    artifacts: artifacts, evidence: [:])
            }
            guard evidence["boot_analysis"] == "prompt_detected" else { return .rejected("boot analysis reported no prompt") }
            return .verified(artifacts: artifacts, evidence: [:])
        }
    }

    // MARK: Helpers

    /// Polls until no process holds the bundle lock. Returns false when the
    /// lock is still held after `lockReleaseTimeout`; never waits longer.
    func waitForLockRelease(_ bundleURL: URL) -> Bool {
        let deadline = Date().addingTimeInterval(lockReleaseTimeout)
        while lockHeld(bundleURL) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: lockPollInterval)
        }
        return true
    }

    func lockStillHeld(_ when: String) -> String {
        "bundle lock still held \(Self.seconds(lockReleaseTimeout)) \(when)"
    }

    static func seconds(_ interval: TimeInterval) -> String {
        interval >= 1 ? "\(Int(interval))s" : String(format: "%.2fs", interval)
    }

    static func restoreTree(_ bundleURL: URL) -> URL? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: bundleURL.path)) ?? [])
            .filter { $0.hasPrefix("iPhone") && $0.hasSuffix("_Restore") }
        guard names.count == 1 else { return nil }
        return bundleURL.appendingPathComponent(names[0])
    }

    static func manifestVersions(_ tree: URL) -> [String: String]? {
        func read(_ name: String) -> (String, String)? {
            guard let data = try? Data(contentsOf: tree.appendingPathComponent(name)),
                  let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let version = root["ProductVersion"] as? String, let build = root["ProductBuildVersion"] as? String
            else { return nil }
            return (version, build)
        }
        guard let ios = read("iPhone-BuildManifest.plist"), let cloud = read("BuildManifest.plist") else { return nil }
        return ["ios_version": ios.0, "ios_build": ios.1, "cloudos_version": cloud.0, "cloudos_build": cloud.1]
    }

    static func historyEntries(_ bundleURL: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(
            atPath: bundleURL.appendingPathComponent(".firmware-history").path)) ?? [])
    }

    static func diskArtifacts(_ bundleURL: URL, includeRestoreInfo: Bool) -> [VPhoneCreateArtifactSpec] {
        var artifacts = [VPhoneCreateArtifactSpec(name: VPhoneCreateArtifact.diskImage, relativePath: "Disk.img", kind: .fileMetadata)]
        if includeRestoreInfo {
            artifacts.append(.init(name: VPhoneCreateArtifact.restoreInfo, relativePath: "restore-info.json", kind: .sha256File))
        }
        return artifacts
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

// MARK: - VPhoneCreateLiveProber

/// Read-only probe of what an interrupted run may have left running. Every
/// input is injectable so the decision is testable without a VM.
struct VPhoneCreateLiveProber: VPhoneCreateStateProber {
    /// True while some process holds the bundle directory lock.
    var lockHeld: (URL) -> Bool
    /// `ps -axo pid=,command=` output.
    var processList: () -> String
    /// True when a DFU/recovery endpoint with this ECID (`0x…`) answers.
    var recoveryReachable: (String) -> Bool
    /// Image paths attached according to `hdiutil info`.
    var attachedImages: () -> [String]

    static func live(resources: VPhoneResources) -> VPhoneCreateLiveProber {
        VPhoneCreateLiveProber(
            lockHeld: { VPhoneVMLockProbe.isLockHeld(directory: $0) },
            processList: {
                (try? VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="]))?.stdout ?? ""
            },
            recoveryReachable: { ecid in
                guard let python = try? resources.pythonExecutable() else { return false }
                let result = try? VPhoneProcessRunner.runCapturing(
                    python, [resources.pmd3Bridge.path, "recovery-probe", "--ecid", ecid, "--timeout", "2"])
                return result?.succeeded == true
            },
            attachedImages: {
                guard let output = try? VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["info", "-plist"]),
                      let plist = try? PropertyListSerialization.propertyList(from: Data(output.stdout.utf8), format: nil) as? [String: Any],
                      let images = plist["images"] as? [[String: Any]]
                else { return [] }
                return images.compactMap { $0["image-path"] as? String }
            })
    }

    func probe(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) -> VPhoneCreateProbeResult {
        let bundleURL = context.bundleURL
        let name = context.bundleName
        if lockHeld(bundleURL) {
            return .busy(
                detail: "the bundle lock is held; a child of the interrupted run (fw prepare, DFU, CFW or boot) may still be running",
                action: "stop it (`vphone-cli vm stop \(name)`, or wait for it to exit), then resume")
        }
        var evidence = ["bundle lock free"]
        let ps = processList()
        let bootPIDs = VPhoneBootProcessLocator.parsePIDs(ps, configURL: bundleURL.appendingPathComponent("config.plist"))
        if !bootPIDs.isEmpty {
            return .busy(
                detail: "vphone-cli boot process(es) for this bundle are running: \(bootPIDs.map(String.init).joined(separator: ", "))",
                action: "stop them, then resume")
        }
        evidence.append("no boot process")
        switch stage {
        case .restore:
            guard let ecid = Self.recordedECID(bundleURL) else {
                evidence.append("no udid-prediction.txt, so no device was addressed")
                break
            }
            let bridgePIDs = ps.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let text = String(line)
                guard text.contains("pymobiledevice3_bridge.py"), text.contains("restore-"),
                      text.localizedCaseInsensitiveContains(ecid) else { return nil }
                return text.split(whereSeparator: \.isWhitespace).first.map(String.init)
            }
            if !bridgePIDs.isEmpty {
                return .busy(
                    detail: "restore bridge process(es) for ECID \(ecid) are still running: \(bridgePIDs.joined(separator: ", "))",
                    action: "wait for them to exit or stop them; do not start a new restore while they write to the device")
            }
            evidence.append("no restore bridge process for \(ecid)")
            if recoveryReachable(ecid) {
                return .busy(
                    detail: "a DFU/recovery endpoint for ECID \(ecid) still answers although no process holds the bundle lock",
                    action: "find and stop the process that owns this device endpoint, then resume")
            }
            evidence.append("no DFU/recovery endpoint for \(ecid)")
        case .cfw:
            let prefix = bundleURL.standardizedFileURL.path + "/"
            let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let attached = attachedImages().filter { $0.hasPrefix(prefix) || $0.hasPrefix(resolved) }
            if !attached.isEmpty {
                return .busy(
                    detail: "disk images inside the bundle are still attached: \(attached.joined(separator: ", "))",
                    action: "detach them (hdiutil detach), then resume")
            }
            evidence.append("no attached image inside the bundle")
        default:
            break
        }
        return .idle(evidence: evidence.joined(separator: "; "))
    }

    static func recordedECID(_ bundleURL: URL) -> String? {
        guard let text = try? String(contentsOf: bundleURL.appendingPathComponent("udid-prediction.txt"), encoding: .utf8) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "ECID", let ecid = VPhoneBootPatterns.normalizeECID(parts[1]) {
                return "0x" + ecid
            }
            if parts.count == 2, parts[0] == "UDID", let suffix = parts[1].split(separator: "-").last,
               let ecid = VPhoneBootPatterns.normalizeECID(String(suffix)) {
                return "0x" + ecid
            }
        }
        return nil
    }
}

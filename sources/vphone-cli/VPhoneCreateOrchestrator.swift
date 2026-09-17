import FirmwarePatcher
import Foundation
import VPhoneCore

// MARK: - VPhoneCreateError

/// Failure points across the native `vm create` pipeline — the `die()` call
/// sites of `scripts/setup_machine.sh`'s `main()` / `load_device_identity` /
/// `wait_for_recovery` / `wait_for_first_boot_prompt_auto` / `run_boot_analysis`.
enum VPhoneCreateError: Error, CustomStringConvertible {
    case nestedVirtualization
    case unknownVariant(String)
    case lessRequiresRoot
    case fwPrepareFailed(Int32)
    case identityTimedOut(URL)
    case invalidUDID(String)
    case invalidECID(String)
    case udidECIDMismatch(udid: String, ecid: String)
    case bootLockNotAcquired
    case recoveryTimeout
    case restoreGetSHSHFailed(Int32)
    case restoreUpdateFailed(Int32)
    case cfwInstallFailed(Int32)
    case sudoPasswordRequired
    case firstBootPanic
    case firstBootExitedBeforePrompt(Int32)
    case bootAnalysisPanic
    case bootAnalysisExited(Int32)
    case bootAnalysisTimeout
    case lessBootFailed(Int32)
    case alreadyExistsWithCheckpoint(String)
    case childDidNotExit(label: String, timeout: TimeInterval)

    var description: String {
        switch self {
        case .nestedVirtualization:
            "Virtualization.framework guest boot is unavailable inside a VM — run vm create on a non-nested macOS 15+ host"
        case let .unknownVariant(v):
            "unknown variant '\(v)' (regular|dev|jb|exp|less)"
        case .lessRequiresRoot:
            "fw patch for 'less' must be run as root (matches Makefile's `fw_patch_less must be run via sudo`)"
        case let .fwPrepareFailed(code):
            "fw prepare failed (exit \(code))"
        case let .identityTimedOut(path):
            "missing \(path.path); rebuild and retry to regenerate it"
        case let .invalidUDID(v):
            "invalid UDID in udid-prediction.txt: '\(v)'"
        case let .invalidECID(v):
            "invalid ECID in udid-prediction.txt: '\(v)'"
        case let .udidECIDMismatch(udid, ecid):
            "UDID/ECID mismatch in udid-prediction.txt: \(udid) vs 0x\(ecid)"
        case .bootLockNotAcquired:
            "DFU child did not acquire the VM lock; restore was not started"
        case .recoveryTimeout:
            "timed out waiting for the recovery/DFU endpoint"
        case let .restoreGetSHSHFailed(code):
            "restore-get-shsh failed (exit \(code))"
        case let .restoreUpdateFailed(code):
            "restore-update failed (exit \(code))"
        case let .cfwInstallFailed(code):
            "CFW install failed (exit \(code))"
        case .sudoPasswordRequired:
            "CFW install needs root but no sudo password is available — pass --sudo-password "
                + "or run vm create in an interactive terminal"
        case .firstBootPanic:
            "first boot panicked before command injection"
        case let .firstBootExitedBeforePrompt(code):
            "first boot exited before command injection (exit \(code))"
        case .bootAnalysisPanic:
            "boot analysis: panic detected"
        case let .bootAnalysisExited(code):
            "boot analysis: process exited before success marker (exit \(code))"
        case .bootAnalysisTimeout:
            "boot analysis timed out"
        case let .lessBootFailed(code):
            "start VM (less) failed (exit \(code))"
        case let .alreadyExistsWithCheckpoint(name):
            "VM '\(name)' already exists and has a create checkpoint; inspect it with "
                + "`vphone-cli vm create-status \(name)` and continue with `vphone-cli vm create --resume \(name)`"
        case let .childDidNotExit(label, timeout):
            "\(label) did not exit within \(VPhoneCreateLiveStages.seconds(timeout)) after it was stopped; "
                + "it may still hold the bundle lock or the device"
        }
    }
}

extension VPhoneCreateError: LocalizedError {
    var errorDescription: String? { description }
}

// MARK: - VPhoneCreateRuntime

/// Per-invocation settings that do not decide what a create produces and may
/// differ between the first run and a resume.
struct VPhoneCreateRuntime {
    var sudoEnvExtras: [String: String]
    var rootPopup: Bool
    var interactive: Bool
    var verbosity: VPhoneVerbosity
    var keepArtifacts: Bool
}

// MARK: - VPhoneCreateOrchestrator

/// Native port of `scripts/setup_machine.sh`'s `main()` — runs the full
/// `vm create` pipeline (prepare → patch → restore → CFW → first boot → JB
/// finalize → verification) with no `make`/`setup_machine.sh` shell-out.
///
/// Stages run through `VPhoneCreateRunner`, which keeps a checkpoint in the
/// bundle; `VPhoneCreateLiveStages` holds the real executor and verifier.
///
/// Lives in the EXECUTABLE target rather than VPhoneCore because it composes
/// `FirmwarePatcher.FirmwarePipeline`, and `FirmwarePatcher` already depends on
/// `VPhoneCore` (Package.swift) — VPhoneCore importing FirmwarePatcher back
/// would be a package dependency cycle. The regex/ECID primitives this type
/// needs to be independently unit-testable live in VPhoneCore instead, as
/// `VPhoneBootPatterns`, where `VPhoneCoreTests` (which depends only on
/// VPhoneCore) can reach them.
public struct VPhoneCreateOrchestrator {
    public struct Options {
        public var name: String
        public var variant: String
        public var iphoneSource: String?
        public var cloudosSource: String?
        public var sudoPassword: String?
        public var spoofBuild: String?
        public var forceDSCMaxSlide: Bool
        public var enableFrida: Bool
        public var rootPopup: Bool
        public var interactive: Bool
        public var cpuCount: UInt
        public var memoryMB: UInt64
        public var diskSizeGB: UInt64
        public var verbosity: VPhoneVerbosity
        public var keepArtifacts: Bool

        public init(
            name: String,
            variant: String,
            iphoneSource: String? = nil,
            cloudosSource: String? = nil,
            sudoPassword: String? = nil,
            spoofBuild: String? = nil,
            forceDSCMaxSlide: Bool = false,
            enableFrida: Bool = false,
            rootPopup: Bool = false,
            interactive: Bool = false,
            cpuCount: UInt = 8,
            memoryMB: UInt64 = 8192,
            diskSizeGB: UInt64 = 64,
            verbosity: VPhoneVerbosity = .quiet,
            keepArtifacts: Bool = false
        ) {
            self.name = name
            self.variant = variant
            self.iphoneSource = iphoneSource
            self.cloudosSource = cloudosSource
            self.sudoPassword = sudoPassword
            self.spoofBuild = spoofBuild
            self.forceDSCMaxSlide = forceDSCMaxSlide
            self.enableFrida = enableFrida
            self.rootPopup = rootPopup
            self.interactive = interactive
            self.cpuCount = cpuCount
            self.memoryMB = memoryMB
            self.diskSizeGB = diskSizeGB
            self.verbosity = verbosity
            self.keepArtifacts = keepArtifacts
        }
    }

    let library: VPhoneLibrary
    let resources: VPhoneResources
    let selfExecutable: URL

    public init(library: VPhoneLibrary, resources: VPhoneResources, selfExecutable: URL) {
        self.library = library
        self.resources = resources
        self.selfExecutable = selfExecutable
    }

    // MARK: - run

    /// Fresh create: refuses an existing name, creates the bundle, then runs
    /// every stage through the checkpointed runner.
    public func run(_ options: Options) throws {
        // Fail fast on a nested-VM host — PV=3 guest boot can't nest, and the whole
        // create pipeline (download + patch + restore) is wasted otherwise. Mirrors
        // the boot_host_preflight gate that `make boot` applied.
        if try Self.isNestedVMHost() {
            throw VPhoneCreateError.nestedVirtualization
        }

        guard let variantOption = PatchFirmwareCLI.VariantOption(rawValue: options.variant) else {
            throw VPhoneCreateError.unknownVariant(options.variant)
        }
        let isLess = variantOption == .less

        let bundleURL = library.url(forName: options.name)
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            let checkpointDirectory = bundleURL.appendingPathComponent(VPhoneCreateCheckpointStore.directoryName)
            if FileManager.default.fileExists(atPath: checkpointDirectory.path) {
                throw VPhoneCreateError.alreadyExistsWithCheckpoint(options.name)
            }
            throw VPhoneLibraryError.alreadyExists(name: options.name)
        }

        let sudo = try SudoSession(
            needed: !isLess, password: options.sudoPassword, rootPopup: options.rootPopup,
            verbosity: options.verbosity, orchestrator: self)
        defer { sudo.cleanup() }

        print("\n=== vm new ===")
        let spec = VPhoneBundleOps.NewBundleSpec(
            name: options.name, cpuCount: options.cpuCount, memoryMB: options.memoryMB,
            diskSizeGB: options.diskSizeGB,
            romSource: VPhoneBundleOps.defaultROMSource(), sepromSource: VPhoneBundleOps.defaultSEPROMSource())
        let bundle = try VPhoneBundleOps.create(spec, in: library)
        print("created \(bundle.url.path)")

        let effective = VPhoneCreateEffectiveOptions(
            variant: options.variant, iphoneSource: options.iphoneSource, cloudosSource: options.cloudosSource,
            spoofBuild: options.spoofBuild, forceDscMaxSlide: options.forceDSCMaxSlide,
            enableFrida: options.enableFrida, cpuCount: options.cpuCount, memoryMb: options.memoryMB,
            diskSizeGb: options.diskSizeGB)
        let runtime = VPhoneCreateRuntime(
            sudoEnvExtras: sudo.envExtras, rootPopup: options.rootPopup, interactive: options.interactive,
            verbosity: options.verbosity, keepArtifacts: options.keepArtifacts)
        let checkpoint: VPhoneCreateCheckpoint
        do {
            checkpoint = try makeRunner(runtime).create(
                bundleURL: bundle.url, options: effective,
                iphoneSource: options.iphoneSource, cloudosSource: options.cloudosSource)
        } catch {
            let file = bundle.url.appendingPathComponent(VPhoneCreateCheckpointStore.directoryName)
                .appendingPathComponent(VPhoneCreateCheckpointStore.fileName)
            if FileManager.default.fileExists(atPath: file.path) {
                Self.printRecoveryHint(name: options.name, bundleURL: bundle.url, error: error)
            } else {
                // Without a durable checkpoint there is no resume path; do not
                // leave a bundle that blocks the name.
                try? VPhoneBundleOps.delete(bundleNamed: options.name, in: library)
                print("[-] No create checkpoint could be written; removed \(bundle.url.path)")
            }
            throw error
        }
        Self.printOutcome(checkpoint)
    }

    // MARK: - resume

    public struct ResumeOptions {
        public var name: String
        public var overrides: VPhoneCreateRunner.OptionOverrides
        public var restartFrom: VPhoneCreateStage?
        public var acceptToolChange: Bool
        public var sudoPassword: String?
        public var rootPopup: Bool
        public var interactive: Bool
        public var verbosity: VPhoneVerbosity
        public var keepArtifacts: Bool

        public init(
            name: String, overrides: VPhoneCreateRunner.OptionOverrides = .init(),
            restartFrom: VPhoneCreateStage? = nil, acceptToolChange: Bool = false, sudoPassword: String? = nil,
            rootPopup: Bool = false, interactive: Bool = false, verbosity: VPhoneVerbosity = .quiet,
            keepArtifacts: Bool = false
        ) {
            self.name = name
            self.overrides = overrides
            self.restartFrom = restartFrom
            self.acceptToolChange = acceptToolChange
            self.sudoPassword = sudoPassword
            self.rootPopup = rootPopup
            self.interactive = interactive
            self.verbosity = verbosity
            self.keepArtifacts = keepArtifacts
        }
    }

    /// Continues an interrupted create of an existing bundle from its checkpoint.
    public func resume(_ options: ResumeOptions) throws {
        if try Self.isNestedVMHost() {
            throw VPhoneCreateError.nestedVirtualization
        }
        if let variant = options.overrides.variant, PatchFirmwareCLI.VariantOption(rawValue: variant) == nil {
            throw VPhoneCreateError.unknownVariant(variant)
        }
        let bundleURL = try library.bundle(named: options.name).url
        // Read-only look to decide whether sudo is still needed; the runner
        // reloads and validates the checkpoint under its locks.
        let stored = try VPhoneCreateCheckpointStore.load(bundleURL: bundleURL).checkpoint
        let variant = options.overrides.variant ?? stored.effectiveOptions.variant
        let cfwPending = !stored.record(.cfw).status.isDone || options.restartFrom.map { $0 <= .cfw } == true
        let sudo = try SudoSession(
            needed: variant != "less" && cfwPending, password: options.sudoPassword, rootPopup: options.rootPopup,
            verbosity: options.verbosity, orchestrator: self)
        defer { sudo.cleanup() }

        let runtime = VPhoneCreateRuntime(
            sudoEnvExtras: sudo.envExtras, rootPopup: options.rootPopup, interactive: options.interactive,
            verbosity: options.verbosity, keepArtifacts: options.keepArtifacts)
        let checkpoint: VPhoneCreateCheckpoint
        do {
            checkpoint = try makeRunner(runtime).resume(
                bundleURL: bundleURL,
                request: .init(
                    overrides: options.overrides, restartFrom: options.restartFrom,
                    acceptToolChange: options.acceptToolChange))
        } catch {
            Self.printRecoveryHint(name: options.name, bundleURL: bundleURL, error: error)
            throw error
        }
        Self.printOutcome(checkpoint)
    }

    func makeRunner(_ runtime: VPhoneCreateRuntime) -> VPhoneCreateRunner {
        let stages = VPhoneCreateLiveStages(orchestrator: self, runtime: runtime)
        let executable = selfExecutable
        return VPhoneCreateRunner(
            executor: stages, verifier: stages, prober: VPhoneCreateLiveProber.live(resources: resources),
            toolFingerprint: { try? VPhoneCreateDigest.sha256(fileAt: executable).digest },
            keepArtifacts: runtime.keepArtifacts)
    }

    // MARK: - outcome

    static func printOutcome(_ checkpoint: VPhoneCreateCheckpoint) {
        print("\n=== Done ===")
        switch checkpoint.overallStatus {
        case .succeeded:
            print("Setup completed: every applicable stage succeeded and was verified.")
        case .completedUnverified:
            print("Setup finished, but not every stage could be verified (overall: completed_unverified):")
            for record in checkpoint.stages where record.status == .unverified {
                print("  \(record.stage.rawValue): \(record.reason ?? "no reason recorded")")
            }
        default:
            print("Setup did not complete (overall: \(checkpoint.overallStatus.rawValue)).")
        }
    }

    static func printRecoveryHint(name: String, bundleURL: URL, error: Error) {
        let lines = recoveryHintLines(
            name: name, bundleURL: bundleURL, error: error,
            holder: { VPhoneVMRuntimeState.read(in: $0).flatMap { record in
                guard let identity = VPhoneProcessInfo.identity(of: record.pid), !identity.isZombie else { return nil }
                return "pid \(record.pid) running operation \"\(record.operation)\""
            } })
        guard !lines.isEmpty else { return }
        print("\n" + lines.joined(separator: "\n"))
        // stdout is buffered when redirected; flush so the hint precedes the
        // `Error:` line ArgumentParser writes to stderr afterwards.
        fflush(stdout)
    }

    /// The hint printed after a failed create or resume.
    ///
    /// A refusal because the bundle or the checkpoint is in use leads with the
    /// stop/wait guidance: resuming again before the holder exits is refused
    /// the same way. Such refusals write nothing, so the checkpoint's derived
    /// status is reported as unchanged rather than as `recovery_required`.
    /// `holder` describes the live holder of the bundle lock from the runtime
    /// record (nil when the record is absent or names an exited pid).
    static func recoveryHintLines(
        name: String, bundleURL: URL, error: Error, holder: (URL) -> String? = { _ in nil }
    ) -> [String] {
        let checkpoint = try? VPhoneCreateCheckpointStore.load(bundleURL: bundleURL).checkpoint
        let inspect = "    Inspect: vphone-cli vm create-status \(name)"
        let resume = "    Resume:  vphone-cli vm create --resume \(name)"
        let unchanged = checkpoint.map { "the checkpoint was not changed (overall: \($0.overallStatus.rawValue))" }
            ?? "the checkpoint was not changed"
        switch error {
        case VPhoneCreateRunError.bundleBusy:
            var lines = ["[-] vm create --resume refused: the bundle is in use; \(unchanged)."]
            if let holder = holder(bundleURL) { lines.append("    holder (runtime record): \(holder)") }
            lines += [
                "    action: wait for the interrupted run's children (fw prepare, DFU/restore, CFW or boot) to exit, "
                    + "or stop the VM (`vphone-cli vm stop \(name)`)",
                "    then check that `vphone-cli vm create-status \(name) --json` reports live.bundle_lock_held = false,",
                "    and resume: vphone-cli vm create --resume \(name)",
            ]
            return lines
        case VPhoneCreateRunError.runInProgress:
            return [
                "[-] vm create --resume refused: another vm create or resume of \(name) is running; \(unchanged).",
                "    action: wait for that run to exit (`vphone-cli vm create-status \(name)` reports overall: running while it holds the checkpoint)",
                "    and resume only if it stopped before completing: vphone-cli vm create --resume \(name)",
            ]
        case let VPhoneCreateRunError.recoveryRequired(requirement):
            // Thrown before any write, so the requirement is not in the checkpoint.
            return [
                "[-] vm create --resume refused: recovery required (\(requirement.kind)"
                    + (requirement.stage.map { ", stage \($0.rawValue)" } ?? "") + "); \(unchanged).",
                "    detail: \(requirement.detail)",
                "    action: \(requirement.action)",
                inspect, resume,
            ]
        default:
            break
        }
        guard let checkpoint else { return [] }
        var lines = ["[-] vm create stopped (overall: \(checkpoint.overallStatus.rawValue)); recovery inputs are kept."]
        if let requirement = checkpoint.recoveryRequired {
            lines.append("    recovery required: \(requirement.detail)")
            lines.append("    action: \(requirement.action)")
        }
        switch error {
        case VPhoneCreateRunError.artifactChanged, VPhoneCreateRunError.artifactUnavailable:
            lines.append("    Recorded inputs changed or were removed. Restart from the stage that produces them "
                + "(vphone-cli vm create --resume \(name) --restart-from prepare), or delete the VM and create it again.")
        default:
            lines += [inspect, resume]
        }
        return lines
    }

    // MARK: - trace

    /// Internal spawn/outcome trace, gated on `.trace` (`-vvv`). Never prints
    /// secret env VALUES (e.g. SUDO_PASSWORD) — callers pass only key names.
    func trace(_ msg: String, _ v: VPhoneVerbosity) {
        guard v.tracesInternals else { return }
        print("[trace] \(msg)")
    }

    /// `-v` repeated `min(v.rawValue, 2)` times, for the pmd3 bridge's own
    /// `--verbose`/`-v` count option (`.info`→1 INFO / pmd3's colorful default,
    /// `.debug`/`.trace`→2 DEBUG). `-v` on `vm create` thus surfaces the pmd3
    /// restore logs, which is the whole point of asking for verbosity.
    private func pmd3VerbosityArgs(_ v: VPhoneVerbosity) -> [String] {
        Array(repeating: "-v", count: min(v.rawValue, 2))
    }

    // MARK: - nested-VM preflight

    /// True when running inside an Apple VM (`kern.hv_vmm_present == 1`),
    /// where Virtualization.framework PV=3 guest boot is unavailable.
    static func isNestedVMHost() throws -> Bool {
        let r = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/sbin/sysctl"), ["-n", "kern.hv_vmm_present"])
        return VPhoneBootPatterns.parseHVVmmPresent(r.stdout)
    }

    // MARK: - sudo askpass

    /// CFW install re-execs under sudo (host disk mount: mount_apfs + chown
    /// 0:0 are root-only). With --sudo-password we feed sudo non-interactively
    /// via the askpass helper. Otherwise sudo prompts on the terminal itself —
    /// the CFW-install step runs as a foreground job (runForeground) so sudo's
    /// process group owns the tty and reads the password directly; our code
    /// never sees it. `less` runs the whole create as root, so needs no password.
    struct SudoSession {
        var envExtras: [String: String] = [:]
        var askpassScript: URL?

        init(needed: Bool, password: String?, rootPopup: Bool, verbosity: VPhoneVerbosity,
             orchestrator: VPhoneCreateOrchestrator) throws {
            guard needed else { return }
            if let password, !password.isEmpty {
                let script = try orchestrator.makeSudoAskpassScript()
                askpassScript = script
                envExtras = ["SUDO_ASKPASS": script.path, "SUDO_PASSWORD": password]
                if orchestrator.preloadSudoCredential(env: envExtras, verbosity: verbosity) {
                    print("[+] sudo credential preloaded via --sudo-password")
                } else {
                    print("[!] --sudo-password failed validation; will still try at CFW-install time")
                }
            } else if !rootPopup && isatty(FileHandle.standardInput.fileDescriptor) == 0 {
                // No password, no popup, no terminal for sudo to prompt on — fail
                // before the long download/restore, not at the eventual sudo prompt.
                throw VPhoneCreateError.sudoPasswordRequired
            }
        }

        func cleanup() {
            if let askpassScript { try? FileManager.default.removeItem(at: askpassScript) }
        }
    }

    /// Askpass helper: emits `$SUDO_PASSWORD` (set per-invocation in the env).
    /// The password is never written into the script itself.
    private func makeSudoAskpassScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-sudo-askpass-\(UUID().uuidString)")
        let script = "#!/bin/sh\nprintf '%s\\n' \"${SUDO_PASSWORD:-}\"\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Validate a sudo credential non-interactively via the askpass env
    /// (`sudo -A -v`). Returns whether it succeeded.
    private func preloadSudoCredential(env extras: [String: String], verbosity v: VPhoneVerbosity) -> Bool {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extras { env[key] = value }
        trace("spawn /usr/bin/sudo -A -v (env keys added: \(extras.keys.sorted().joined(separator: ", ")))", v)
        let result = try? VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/sudo"), ["-A", "-v"], env: env)
        return result?.succeeded == true
    }

    // MARK: - fw prepare / fw patch

    /// Restores the pristine AVPBooter ROM before fw prepare. The patch stage
    /// rewrites it in place, so without this a restart from prepare would patch
    /// an already patched ROM.
    func refreshBootROM(bundleURL: URL) throws {
        try VPhoneBundleGuard.withBundleLock(directory: bundleURL, operation: VPhoneVMOperation.fwPrepare) { _ in
            let target = bundleURL.appendingPathComponent("AVPBooter.vresearch1.bin")
            let staged = bundleURL.appendingPathComponent(".AVPBooter.vresearch1.bin.\(UUID().uuidString)")
            try FileManager.default.copyItem(at: VPhoneBundleOps.defaultROMSource(), to: staged)
            guard rename(staged.path, target.path) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: staged)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
    }

    func runFWPrepare(
        iphoneSource: String?, cloudosSource: String?, isLess: Bool, keepArtifacts: Bool,
        bundleURL: URL, verbosity v: VPhoneVerbosity
    ) throws {
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        if let iphoneSource { env["IPHONE_SOURCE"] = iphoneSource }
        if let cloudosSource { env["CLOUDOS_SOURCE"] = cloudosSource }
        env["VPHONE_PYTHON"] = try resources.pythonExecutable().path
        env["IPSW_DIR"] = resources.ipswCacheDir.path
        env["VPHONE_SEAL_DIR"] = resources.sealVolumeCacheDir.path
        if isLess { env["VARIANT"] = "less" }
        if keepArtifacts { env["VPHONE_KEEP_ARTIFACTS"] = "1" }

        trace("spawn /bin/bash \(resources.fwPrepareScript.path) (env keys: VPHONE_PYTHON, IPSW_DIR, VPHONE_SEAL_DIR)", v)
        // Always streamed — silence during a multi-GB download reads as a hang.
        let code = try VPhoneProcessRunner.runStreaming(
            try resources.pythonExecutable(),
            [resources.fwPrepareScript.deletingLastPathComponent().appendingPathComponent("vm_lock.py").path,
             bundleURL.path, "fw-prepare", "--", "/bin/bash", resources.fwPrepareScript.path], cwd: bundleURL, env: env,
            echo: true)
        guard code == 0 else { throw VPhoneCreateError.fwPrepareFailed(code) }
        print("[+] Firmware prepared (iPhone + cloudOS merged into bundle).")
    }

    @discardableResult
    func runFWPatch(
        variant: PatchFirmwareCLI.VariantOption, isLess: Bool, enableFrida: Bool,
        bundleURL: URL, verbosity v: VPhoneVerbosity
    ) throws -> Int {
        let lock = try VPhoneVMLock(directory: bundleURL, operation: "fw-patch")
        defer { withExtendedLifetime(lock) {} }
        // Mirrors the Makefile's `ifeq ($(UID),0)` gate on `fw_patch_less` —
        // only the `less` variant requires root.
        if isLess, getuid() != 0 {
            throw VPhoneCreateError.lessRequiresRoot
        }

        // In-process pipeline (no subprocess) — CryptexFilesystemPatcher's
        // apfs_sealvolume read honors VPHONE_SEAL_DIR from *this* process's
        // environment, so set it here to agree with `fw prepare`'s write.
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        setenv("VPHONE_SEAL_DIR", resources.sealVolumeCacheDir.path, 1)

        trace("in-process FirmwarePipeline.patchAll variant=\(variant.rawValue)", v)
        let pipeline = FirmwarePipeline(
            vmDirectory: bundleURL, variant: variant.pipelineVariant, verbose: v.showsToolDetail,
            noBinpack: false, noVphoned: false, forceExcGuard: false,
            enableFrida: enableFrida)
        let records = try pipeline.patchAll()
        print("[fw patch] applied \(records.count) patches for \(variant.rawValue)")
        return records.count
    }

    // MARK: - managed children

    /// Upper bound on waiting for a stopped stage child to exit.
    static let childExitTimeout: TimeInterval = 60

    /// Runs `body`, then stops the stage's child and waits until it has exited,
    /// on the success and the error path alike, so the stage's verifier never
    /// runs while the child still holds the bundle lock or the device.
    ///
    /// The wait is bounded by `timeout`. After a successful body a child that
    /// does not exit fails the stage with `childDidNotExit`; after a failed
    /// body the original error is kept and the stuck child is only reported.
    static func withStoppedChild<T>(
        _ label: String, timeout: TimeInterval = childExitTimeout,
        stop: () -> Void, awaitExit: (TimeInterval) -> Bool, _ body: () throws -> T
    ) throws -> T {
        let result: T
        do {
            result = try body()
        } catch {
            stop()
            if !awaitExit(timeout) {
                print("[!] \(label) did not exit within \(VPhoneCreateLiveStages.seconds(timeout)) after it was stopped.")
            }
            throw error
        }
        stop()
        guard awaitExit(timeout) else { throw VPhoneCreateError.childDidNotExit(label: label, timeout: timeout) }
        return result
    }

    static func withStoppedChild<T>(
        _ child: VPhoneManagedProcess, _ label: String, timeout: TimeInterval = childExitTimeout, _ body: () throws -> T
    ) throws -> T {
        try withStoppedChild(
            label, timeout: timeout, stop: { child.terminate() }, awaitExit: { awaitExit(child, timeout: $0) }, body)
    }

    /// Bounded wait for a managed child to exit. `VPhoneManagedProcess` only
    /// offers an unbounded `waitUntilExit`; a never-matching pattern turns
    /// `waitForOutput` into a short poll that reports `.exited` once it has.
    static func awaitExit(_ child: VPhoneManagedProcess, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if case .exited = child.waitForOutput(matching: "[^\\s\\S]", timeout: min(0.25, max(timeout, 0))) {
                return true
            }
        } while Date() < deadline
        return false
    }

    // MARK: - restore phase

    /// Returns the evidence the restore verifier checks.
    func runRestorePhase(bundleURL: URL, verbosity v: VPhoneVerbosity) throws -> [String: String] {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        print("[*] Starting DFU boot in background...")
        // Guest serial is never teed during `vm create` (echo: false); the
        // managed process still reads it internally for panic/prompt matching.
        trace("spawn \(selfExecutable.path) --config \(configURL.path) --dfu (guest serial: off)", v)
        let dfu = VPhoneManagedProcess(
            selfExecutable, ["--config", configURL.path, "--dfu"], cwd: bundleURL, echo: false)
        try dfu.start()
        return try Self.withStoppedChild(dfu, "DFU boot process") {
            try restoreWithDFU(dfu, bundleURL: bundleURL, verbosity: v)
        }
    }

    private func restoreWithDFU(
        _ dfu: VPhoneManagedProcess, bundleURL: URL, verbosity v: VPhoneVerbosity
    ) throws -> [String: String] {
        guard case .matched = dfu.waitForOutput(matching: "VM lock acquired", timeout: 30) else {
            throw VPhoneCreateError.bootLockNotAcquired
        }

        let (udid, ecid) = try loadDeviceIdentity(bundleURL: bundleURL)
        print("[+] Device identity loaded: UDID=\(udid) ECID=0x\(ecid)")

        try waitForRecovery(ecid: ecid, verbosity: v)

        let python = try resources.pythonExecutable()
        let verbosityArgs = pmd3VerbosityArgs(v)
        print("[*] Fetching SHSH blob...")
        let shshArgs =
            [resources.pmd3Bridge.path, "restore-get-shsh", "--vm-dir", ".", "--udid", udid, "--ecid", "0x\(ecid)"]
            + verbosityArgs
        trace("spawn \(python.path) \(shshArgs.joined(separator: " "))", v)
        let shshCode = try VPhoneProcessRunner.runStreaming(python, shshArgs, cwd: bundleURL, echo: v.showsToolDetail)
        guard shshCode == 0 else { throw VPhoneCreateError.restoreGetSHSHFailed(shshCode) }

        print("[*] Restoring...")
        let restoreArgs =
            [resources.pmd3Bridge.path, "restore-update", "--vm-dir", ".", "--udid", udid, "--ecid", "0x\(ecid)"]
            + verbosityArgs
        trace("spawn \(python.path) \(restoreArgs.joined(separator: " "))", v)
        let restoreCode = try VPhoneProcessRunner.runStreaming(
            python, restoreArgs, cwd: bundleURL, echo: v.showsToolDetail)
        guard restoreCode == 0 else { throw VPhoneCreateError.restoreUpdateFailed(restoreCode) }

        recordRestoreVersions(bundleURL: bundleURL)

        // wait_for_post_restore_reboot: a plain case-insensitive 'panic' grep —
        // distinct from (narrower than) BOOT_PANIC_REGEX used elsewhere.
        print("[*] Restore complete; waiting up to 30s for reboot/panic before stopping DFU...")
        let dfuOutcome = dfu.waitForOutput(matching: "(?i)panic|kernel panic", timeout: 30)
        trace("DFU managed-process outcome: \(dfuOutcome)", v)
        switch dfuOutcome {
        case .matched:
            print("[+] Panic marker observed; stopping DFU now.")
        case .exited:
            print("[*] DFU process exited during post-restore reboot window.")
        case .timedOut:
            print("[*] No panic marker observed in 30s; stopping DFU anyway.")
        }
        // runRestorePhase stops the DFU process and waits for it to exit on every path.
        return [
            "udid": udid, "ecid": "0x\(ecid)", "restore_get_shsh_exit": "0", "restore_update_exit": "0",
            "post_restore_dfu_outcome": "\(dfuOutcome)",
        ]
    }

    /// Snapshot the just-restored iOS + cloudOS versions to `restore-info.json`,
    /// read host-side from the bundle's restore-dir plists. Best-effort: the
    /// restore already succeeded, so a metadata miss is a warning, not a failure.
    private func recordRestoreVersions(bundleURL: URL) {
        guard let bundle = try? VPhoneBundle.load(at: bundleURL),
              let info = VPhoneRestoreInfo.derive(fromBundle: bundle)
        else {
            print("[!] Could not record restore versions (metadata not found)")
            return
        }
        do {
            try info.write(toBundle: bundle)
            print("[+] Recorded versions: iOS \(info.ios.version) (\(info.ios.build)), "
                + "cloudOS \(info.cloudOS.version) (\(info.cloudOS.build))")
        } catch {
            print("[!] Could not write restore-info.json: \(error)")
        }
    }

    func loadDeviceIdentity(bundleURL: URL, wait: TimeInterval = 30) throws -> (udid: String, ecid: String) {
        let predictionFile = bundleURL.appendingPathComponent("udid-prediction.txt")
        let deadline = Date().addingTimeInterval(wait)
        while !FileManager.default.fileExists(atPath: predictionFile.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        guard FileManager.default.fileExists(atPath: predictionFile.path) else {
            throw VPhoneCreateError.identityTimedOut(predictionFile)
        }

        let text = (try? String(contentsOf: predictionFile, encoding: .utf8)) ?? ""
        var udid = ""
        var ecid = ""
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq]
            let value = String(line[line.index(after: eq)...])
            if key == "UDID" { udid = value.uppercased() }
            if key == "ECID" { ecid = VPhoneBootPatterns.normalizeECID(value) ?? "" }
        }

        guard udid.range(of: "^[0-9A-F]{8}-[0-9A-F]{16}$", options: .regularExpression) != nil else {
            throw VPhoneCreateError.invalidUDID(udid)
        }
        if ecid.isEmpty {
            ecid = udid.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
        }
        guard ecid.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil else {
            throw VPhoneCreateError.invalidECID(ecid)
        }
        let udidSuffix = udid.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
        guard udidSuffix == ecid else {
            throw VPhoneCreateError.udidECIDMismatch(udid: udid, ecid: ecid)
        }
        return (udid, ecid)
    }

    private func waitForRecovery(ecid: String, verbosity v: VPhoneVerbosity) throws {
        print("[*] Waiting for recovery/DFU endpoint...")
        let python = try resources.pythonExecutable()
        for _ in 1...90 {
            let result = try? VPhoneProcessRunner.runCapturing(
                python, [resources.pmd3Bridge.path, "recovery-probe", "--ecid", "0x\(ecid)", "--timeout", "2"])
            if result?.succeeded == true {
                print("[+] Device endpoint is reachable")
                return
            }
            Thread.sleep(forTimeInterval: 2)
        }
        trace("recovery-probe: exhausted 90 retries", v)
        throw VPhoneCreateError.recoveryTimeout
    }

    // MARK: - CFW install

    func runCFWInstall(options: VPhoneCreateEffectiveOptions, runtime: VPhoneCreateRuntime, bundleURL: URL) throws {
        let v = runtime.verbosity
        let sudoEnvExtras = runtime.sudoEnvExtras
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.debsCacheDir, withIntermediateDirectories: true)
        var scriptEnv: [String: String] = [
            "VPHONE_PYTHON": try resources.pythonExecutable().path,
            "IPSW_DIR": resources.ipswCacheDir.path,
            "VPHONE_SEAL_DIR": resources.sealVolumeCacheDir.path,
            "VPHONE_DEBS_DIR": resources.debsCacheDir.path,
        ]
        if let spoofBuild = options.spoofBuild { scriptEnv["SPOOF_BUILD"] = spoofBuild }
        if options.forceDscMaxSlide { scriptEnv["FORCE_DSC_MAXSLIDE"] = "1" }
        if options.enableFrida { scriptEnv["VPHONE_FRIDA"] = "1" }
        if runtime.keepArtifacts { scriptEnv["VPHONE_KEEP_ARTIFACTS"] = "1" }

        let args = [resources.cfwInstallHostScript.path, "--variant", options.variant, bundleURL.path]
        // --sudo-password (askpass) wins over --root-popup.
        let usePopup = runtime.rootPopup && sudoEnvExtras["SUDO_ASKPASS"] == nil
        let code: Int32
        if usePopup {
            // Forward SUDO_USER (sudo would set it) so the script's chown-back runs.
            scriptEnv["SUDO_USER"] = NSUserName()
            trace("osascript admin-privileges /bin/zsh \(args.joined(separator: " "))", v)
            code = try VPhoneProcessRunner.runWithAdminPrivileges(
                URL(fileURLWithPath: "/bin/zsh"), args, env: scriptEnv, echo: v.showsToolDetail)
        } else {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in scriptEnv { env[key] = value }
            for (key, value) in sudoEnvExtras { env[key] = value }
            let envKeys = (["VPHONE_PYTHON", "IPSW_DIR", "VPHONE_SEAL_DIR"] + sudoEnvExtras.keys.sorted()).joined(separator: ", ")
            trace("spawn /bin/zsh \(args.joined(separator: " ")) (env keys: \(envKeys))", v)
            // With an askpass credential sudo is non-interactive → honor verbosity.
            // Without one, sudo must prompt on the terminal → run as a foreground
            // job so its process group owns the tty (see runForeground).
            if sudoEnvExtras["SUDO_ASKPASS"] != nil {
                code = try VPhoneProcessRunner.runStreaming(
                    URL(fileURLWithPath: "/bin/zsh"), args, env: env, echo: v.showsToolDetail)
            } else {
                print("[*] CFW install needs root — sudo will prompt for your macOS password.")
                code = try VPhoneProcessRunner.runForeground(
                    URL(fileURLWithPath: "/bin/zsh"), args, env: env, echo: v.showsToolDetail)
            }
        }
        guard code == 0 else { throw VPhoneCreateError.cfwInstallFailed(code) }
        print("[+] CFW installed (\(options.variant)).")
        // The install script released its lock on exit; take a fresh cfw-record
        // lock to record the variant (see recordVariant's doc). A busy lock only
        // skips the bookkeeping here; the cfw verifier then reports the missing record.
        if let bundle = try? VPhoneBundle.load(at: bundleURL) {
            try? VPhoneBundleGuard.withBundleLock(
                directory: bundle.url, operation: VPhoneVMOperation.cfwRecord
            ) { lock in
                if let info = try? VPhoneRestoreInfo.recordVariant(options.variant, toBundle: bundle, holding: lock),
                   info.variant != nil {
                    print("[+] Recorded variant \(options.variant), device \(info.device ?? "?")")
                }
            }
        }
    }

    // MARK: - first boot

    /// Returns `prompt` = matched | timed_out | operator_confirmed, and the boot exit status.
    func runFirstBoot(isLess: Bool, interactive: Bool, bundleURL: URL, verbosity v: VPhoneVerbosity) throws -> [String: String] {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        var args = ["--config", configURL.path]
        if isLess { args += ["--variant", "less"] }
        // --interactive keeps the window: it is the operator's only boot-progress cue.
        if !interactive { args.append("--headless") }

        if interactive {
            print("[*] press Enter to start VM, after the VM has finished booting, press Enter again to finish last stage")
            _ = readLine()
        } else {
            print("[*] non-interactive (default): auto-starting first boot")
        }

        trace("spawn \(selfExecutable.path) \(args.joined(separator: " ")) (guest serial: off)", v)
        let boot = VPhoneManagedProcess(selfExecutable, args, cwd: bundleURL, echo: false)
        try boot.start()
        return try Self.withStoppedChild(boot, "first-boot VM process") {
            try firstBootSession(boot, interactive: interactive, verbosity: v)
        }
    }

    private func firstBootSession(
        _ boot: VPhoneManagedProcess, interactive: Bool, verbosity v: VPhoneVerbosity
    ) throws -> [String: String] {
        var prompt = "operator_confirmed"
        if interactive {
            print("[*] Press Enter once the VM is fully booted")
            _ = readLine()
        } else {
            let outcome = boot.waitForOutput(matching: VPhoneBootPatterns.panicOrPromptRegex, timeout: 60)
            trace("first-boot managed-process outcome: \(outcome)", v)
            switch outcome {
            case .matched:
                if case .matched = boot.waitForOutput(matching: "(?i:\(VPhoneBootPatterns.panicRegex))", timeout: 0) {
                    print("[-] Panic detected while waiting for first-boot shell prompt.")
                    throw VPhoneCreateError.firstBootPanic
                }
                print("[+] First-boot shell prompt detected")
                prompt = "matched"
            case let .exited(code):
                print("[-] make boot exited before first-boot command injection.")
                throw VPhoneCreateError.firstBootExitedBeforePrompt(code)
            case .timedOut:
                print("[!] Shell prompt not detected within 60s; fallback to timed continue.")
                prompt = "timed_out"
            }
        }

        for cmd in VPhoneBootPatterns.firstBootCommands {
            boot.send(cmd)
        }

        print("[*] Commands sent. Waiting for VM shutdown...")
        let exit = boot.waitUntilExit()
        return ["prompt": prompt, "commands_sent": "\(VPhoneBootPatterns.firstBootCommands.count)", "boot_exit": "\(exit)"]
    }

    // MARK: - boot analysis

    func runBootAnalysis(bundleURL: URL, verbosity v: VPhoneVerbosity) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        trace("spawn \(selfExecutable.path) --config \(configURL.path) --headless (guest serial: off)", v)
        let vm = VPhoneManagedProcess(
            selfExecutable, ["--config", configURL.path, "--headless"], cwd: bundleURL, echo: false)
        try vm.start()
        try Self.withStoppedChild(vm, "boot-analysis VM process") {
            try analyzeBoot(vm, verbosity: v)
        }
    }

    private func analyzeBoot(_ vm: VPhoneManagedProcess, verbosity v: VPhoneVerbosity) throws {
        let outcome = vm.waitForOutput(matching: VPhoneBootPatterns.panicOrPromptRegex, timeout: 300)
        trace("boot-analysis managed-process outcome: \(outcome)", v)
        switch outcome {
        case .matched:
            if case .matched = vm.waitForOutput(matching: "(?i:\(VPhoneBootPatterns.panicRegex))", timeout: 0) {
                print("[-] Boot analysis: panic detected, stopping VM.")
                throw VPhoneCreateError.bootAnalysisPanic
            }
            print("[+] Boot analysis: bash prompt detected, boot success.")
        case let .exited(code):
            print("[-] Boot analysis: VM process exited before success marker.")
            throw VPhoneCreateError.bootAnalysisExited(code)
        case .timedOut:
            print("[-] Boot analysis timeout (300s); stopping VM.")
            throw VPhoneCreateError.bootAnalysisTimeout
        }
    }

    /// `less` variant: `run_make "Start VM" boot_less` — a plain foreground
    /// boot, no panic/prompt analysis (patchless compat mode has no CFW-driven
    /// success marker to watch for).
    func startVMForeground(bundleURL: URL, verbosity v: VPhoneVerbosity) throws {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        print("\n=== Start VM ===")
        let args = ["--config", configURL.path, "--variant", "less"]
        trace("spawn \(selfExecutable.path) \(args.joined(separator: " ")) (echo=\(v.showsToolDetail))", v)
        let code = try VPhoneProcessRunner.runStreaming(
            selfExecutable, args, cwd: bundleURL, echo: v.showsToolDetail)
        guard code == 0 else { throw VPhoneCreateError.lessBootFailed(code) }
    }
}

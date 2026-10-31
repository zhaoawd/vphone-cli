import ArgumentParser
import Foundation
import FirmwarePatcher
import CryptoKit
import VPhoneCore
import Darwin

// MARK: - restore

struct VPhoneRestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "DFU-restore firmware into a VM bundle (requires a running DFU boot)")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Only fetch the SHSH blob, do not restore") var getShsh = false
    @Flag(name: .shortAndLong, help: "Offline restore (decrypt AEA images in place, use the cached .shsh)") var offline = false
    @Option(name: .shortAndLong, help: "Device UDID (optional)") var udid: String?
    @Option(name: .shortAndLong, help: "Device ECID (default: read from the bundle's udid-prediction.txt)") var ecid: String?
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        guard let ecidValue = VPhoneRestoreOps.resolveECID(explicit: ecid, bundle: bundle) else {
            throw VPhoneRestoreError.ecidUnresolved
        }

        func pmd3(_ subcommand: String, extra: [String]) throws -> Int32 {
            var args = [resources.pmd3Bridge.path, subcommand, "--vm-dir", "."]
            if let udid { args += ["--udid", udid] }
            args += ["--ecid", ecidValue] + extra
            // -v (.info) → pmd3 INFO (its colorful log level), -vv/-vvv → DEBUG.
            args += Array(repeating: "-v", count: min(v.rawValue, 2))
            let python = try resources.pythonExecutable()
            if v.tracesInternals {
                print("[trace] spawning: \(python.path) \(args.joined(separator: " "))")
            }
            return try VPhoneProcessRunner.runStreaming(python, args, cwd: bundle.url, echo: v.showsToolDetail)
        }

        // A restore drives a device that only exists while a DFU boot runs, and
        // that boot holds the bundle lock for its whole session. So this command
        // cannot take the lock; it verifies the holder instead. Both paths below
        // talk to the device, so both require the DFU session.
        func requireDFUSession() throws {
            let record = try VPhoneBundleGuard.requireDFUOwner(
                directory: bundle.url, configURL: bundle.configURL)
            if v.tracesInternals {
                print("[trace] DFU session confirmed: pid \(record.pid), instance \(record.instanceID)")
            }
        }

        if getShsh {
            try requireDFUSession()
            throw ExitCode(try pmd3("restore-get-shsh", extra: []))
        }

        let code: Int32
        if offline {
            let fm = FileManager.default
            let shshes = ((try? fm.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "shsh" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let shsh = shshes.first else { throw VPhoneRestoreError.noSHSH }
            let restoreDir = ((try? fm.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("iPhone") && $0.lastPathComponent.hasSuffix("_Restore") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first
            guard let restoreDir else { throw VPhoneRestoreError.noRestoreDir }
            print("[restore] decrypting AEA images in \(restoreDir.lastPathComponent)...")
            // Decryption rewrites files in the bundle, so it is an exclusive
            // offline operation and takes the lock itself. It therefore has to
            // finish BEFORE the DFU boot that the restore step cooperates with
            // is started — a running DFU session holds the lock and this step
            // refuses.
            try VPhoneBundleGuard.withBundleLock(
                directory: bundle.url, operation: VPhoneVMOperation.restoreDecrypt
            ) { _ in
                try VPhoneRestoreOps.decryptAEAImages(inRestoreDir: restoreDir)
            }
            try requireDFUSession()
            code = try pmd3("restore-update", extra: ["--tss", shsh.path])
        } else {
            try requireDFUSession()
            code = try pmd3("restore-update", extra: [])
        }

        if code == 0 { recordRestoreVersions(bundle: bundle) }
        throw ExitCode(code)
    }

    /// Snapshot the just-restored iOS + cloudOS versions to `restore-info.json`,
    /// read host-side from the bundle's restore-dir plists. Best-effort: the
    /// restore already succeeded, so a metadata miss is only a warning.
    private func recordRestoreVersions(bundle: VPhoneBundle) {
        guard let info = VPhoneRestoreInfo.derive(fromBundle: bundle) else {
            FileHandle.standardError.write(Data("warning: could not record restore versions (metadata not found)\n".utf8))
            return
        }
        do {
            try info.write(toBundle: bundle)
            print("[restore] recorded iOS \(info.ios.version) (\(info.ios.build)) / "
                + "cloudOS \(info.cloudOS.version) (\(info.cloudOS.build))")
        } catch {
            FileHandle.standardError.write(Data("warning: could not write restore-info.json: \(error)\n".utf8))
        }
    }
}

// MARK: - cfw

struct VPhoneCFWCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cfw",
        abstract: "Custom-firmware install (host-mount; VM must be off; re-execs sudo)",
        subcommands: [VPhoneCFWInstallCommand.self, VPhoneCFWUndoCommand.self, VPhoneCFWReceiptsCommand.self,
                      VPhoneCFWVerifyEffectsCommand.self,
                      VPhoneCFWUpdateEnvironmentCommand.self, VPhoneCFWVerifyPlanCommand.self,
                      VPhoneCFWVerifyOriginSourceCommand.self, VPhoneCFWRecoverOriginCommand.self])
}

struct VPhoneCFWInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Install CFW into a VM bundle via host mount")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: [.customShort("V"), .long], help: "variant: regular | dev | jb | exp") var variant: String?
    @Option(help: "Guest environment: classic (default) or v2 (regular only; recorded v2 VM required)")
    var guestEnvironment: VPhoneGuestEnvironmentProfile = .classic
    @Option(name: [.customShort("b"), .long], help: "(exp only) rewrite ProductBuildVersion to this build id") var spoofBuild: String?
    @Flag(name: .customLong("root-popup"), help: "Elevate via macOS's native authentication dialog (osascript) instead of the sudo re-exec") var rootPopup = false
    @Option(name: .customLong("work-parent"), help: "Root-owned private or sticky mount workspace parent; disk staging stays on the VM volume")
    var workParent: String?
    @Flag(name: .customLong("keep-artifacts"), help: "Keep the extracted CFW input dirs (cfw_input/, cfw_jb_input/) after install (default: removed to save space)") var keepArtifacts = false
    @Flag(name: .customLong("reinstall-cryptex"), help: "Replace existing Cryptex trees from bound original firmware (regular/classic only)") var reinstallCryptex = false
    @Flag(name: .customLong("qualify-origin"), help: "Require the live selected Core Bundle producer and publish Guest origin with the disk transaction")
    var qualifyOrigin = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    mutating func validate() throws {
        if let variant { try guestEnvironment.validateVariant(variant) }
        try Self.validateCryptexReinstall(reinstallCryptex, variant: variant, guestEnvironment: guestEnvironment)
    }

    static func validateCryptexReinstall(_ enabled: Bool, variant: String?, guestEnvironment: VPhoneGuestEnvironmentProfile) throws {
        if enabled && (guestEnvironment != .classic || (variant != nil && variant != "regular")) {
            throw ValidationError("--reinstall-cryptex requires regular/classic CFW installation")
        }
    }

    static func arguments(script: URL, directory: URL, variant: String,
                          guestEnvironment: VPhoneGuestEnvironmentProfile, reinstallCryptex: Bool, workParent: String? = nil) -> [String] {
        var args = [script.path, "--variant", variant]
        if guestEnvironment == .v2 { args += ["--guest-environment", "v2"] }
        if reinstallCryptex { args.append("--reinstall-cryptex") }
        if let workParent { args += ["--work-parent", workParent] }
        return args + [directory.path]
    }

    static func validateRecordedEnvironment(requested: VPhoneGuestEnvironmentProfile, recorded: VPhoneGuestEnvironmentProfile) throws {
        guard requested == recorded else {
            throw ValidationError("guest environment differs from restore-info.json; migration is not supported by cfw install")
        }
    }

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        try Self.validateRecordedEnvironment(requested: guestEnvironment, recorded: VPhoneRestoreInfo.load(fromBundle: bundle)?.effectiveGuestEnvironment ?? .classic)
        if qualifyOrigin {
            try VPhoneCFWTrustedProducer.requireDefaultResources(projectRoot: projectRoot,
                environment: ProcessInfo.processInfo.environment)
            if geteuid() != 0 {
                var args = ["cfw", "install", name, "--library-root", lib.library.root.path,
                    "--qualify-origin", "--guest-environment", guestEnvironment.rawValue]
                if let variant { args += ["--variant", variant] }
                if let spoofBuild { args += ["--spoof-build", spoofBuild] }
                if let workParent { args += ["--work-parent", workParent] }
                if keepArtifacts { args.append("--keep-artifacts") }
                if reinstallCryptex { args.append("--reinstall-cryptex") }
                args += Array(repeating: "-v", count: verboseCount)
                let executable = VPhoneResources.runningExecutable()
                var environment = VPhoneInvoker.environment()
                environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
                let code: Int32
                if rootPopup {
                    code = try VPhoneProcessRunner.runWithAdminPrivileges(executable, args, env: environment)
                } else {
                    code = try VPhoneProcessRunner.runStreaming(URL(fileURLWithPath: "/usr/bin/sudo"),
                        ["-E", executable.path] + args, env: environment)
                }
                throw ExitCode(code)
            }
            let code = try VPhoneCFWTrustedProducer.withLease(machine: bundle.url) { environment, input in
                try install(bundle: bundle, sourceEnvironment: environment, input: input)
            }
            throw ExitCode(code)
        }
        throw ExitCode(try install(bundle: bundle))
    }

    func install(bundle: VPhoneBundle, sourceEnvironment: [String: String] = [:], input: FileHandle? = nil) throws -> Int32 {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        // Qualified producers must not provision an unplanned root runtime.
        let python = try resources.pythonExecutable(allowBootstrap: input == nil)
        let frozen = try VPhoneBundleGuard.withBundleLock(directory: bundle.url, operation: VPhoneVMOperation.cfwRecord) { _ in
            try VPhoneCFWFrozenContext.prepare(in: bundle.url, requestedVariant: self.variant,
                guestEnvironment: guestEnvironment.rawValue, spoofBuild: spoofBuild ?? "")
        }
        let variant = frozen.variant
        try Self.validateCryptexReinstall(reinstallCryptex, variant: variant, guestEnvironment: guestEnvironment)

        // Env the bundled scripts read: rides along via `sudo -E` by default;
        // --root-popup forwards it inline (do shell script's bare env).
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.debsCacheDir, withIntermediateDirectories: true)
        var scriptEnv: [String: String] = [
            "VPHONE_PYTHON": python.path,
            "VPHONE_FROZEN_PLAN": bundle.url.appendingPathComponent(FirmwareDesiredPlanStore.filename).path,
            "VPHONE_FROZEN_PLAN_SHA256": frozen.rawSHA256,
            "VPHONE_FROZEN_CONTEXT": try frozen.json,
            "VPHONE_CFW_VARIANT": variant,
            "VPHONE_GUEST_ENVIRONMENT": guestEnvironment.rawValue,
            "VPHONE_FRIDA": frozen.enableFrida ? "1" : "0",
            "DISABLE_LAUNCHD_HOOK": frozen.disableLaunchdHook,
            "IPSW_DIR": resources.ipswCacheDir.path,
            "VPHONE_SEAL_DIR": resources.sealVolumeCacheDir.path,
            "VPHONE_DEBS_DIR": resources.debsCacheDir.path,
        ]
        if let spoofBuild { scriptEnv["SPOOF_BUILD"] = spoofBuild }
        if keepArtifacts { scriptEnv["VPHONE_KEEP_ARTIFACTS"] = "1" }

        if guestEnvironment == .v2 {
            scriptEnv["VPHONE_GUEST_COMPONENTS"] = ProcessInfo.processInfo.environment["VPHONE_GUEST_COMPONENTS"] ?? resources.guestComponentsStage.path
            scriptEnv["VPHONE_API_DAEMON"] = ProcessInfo.processInfo.environment["VPHONE_API_DAEMON"] ?? resources.daemonAPICandidate.path
        }
        let args = Self.arguments(script: resources.cfwInstallHostScript, directory: bundle.url,
            variant: variant, guestEnvironment: guestEnvironment, reinstallCryptex: reinstallCryptex, workParent: workParent)
        // Both paths carry VPHONE_INVOKER_UID/GID so the driver returns the
        // artifacts it creates as root (the popup sets no SUDO_UID).
        scriptEnv.merge(sourceEnvironment) { _, source in source }
        var invoker = VPhoneInvoker.environment()
        if input != nil, let uid = ProcessInfo.processInfo.environment[VPhoneInvoker.uidKey] {
            invoker[VPhoneInvoker.uidKey] = uid
            invoker[VPhoneInvoker.gidKey] = ProcessInfo.processInfo.environment[VPhoneInvoker.gidKey]
        }
        var invocation = VPhoneCreateOrchestrator.cfwInvocation(
            scriptEnv: scriptEnv, sudoEnvExtras: [:], rootPopup: rootPopup && input == nil, invoker: invoker)
        if input == nil { invocation.env.removeValue(forKey: "VPHONE_CFW_ORIGIN_SOURCE") }
        let code: Int32
        if invocation.usePopup {
            code = try VPhoneProcessRunner.runWithAdminPrivileges(
                URL(fileURLWithPath: "/bin/zsh"), args, env: invocation.env, echo: v.showsToolDetail)
        } else {
            if v.tracesInternals {
                print("[trace] spawning: /bin/zsh \(args.joined(separator: " ")) (env keys: VPHONE_PYTHON, IPSW_DIR, VPHONE_SEAL_DIR, \(VPhoneInvoker.uidKey), \(VPhoneInvoker.gidKey))")
            }
            code = try VPhoneProcessRunner.runStreaming(
                URL(fileURLWithPath: "/bin/zsh"), args, env: invocation.env, echo: v.showsToolDetail, input: input)
        }
        if code == 0 {
            // The CFW install script released its own lock when it exited, so a
            // fresh cfw-record lock is available. Recording the variant and the
            // optional cleanup are one lock lifetime (see recordVariant's doc).
            // A busy lock (VM running) only skips the bookkeeping — the install
            // already succeeded, so do not abort the process.
            let recorded: Void? = try? VPhoneBundleGuard.withBundleLock(
                directory: bundle.url, operation: VPhoneVMOperation.cfwRecord
            ) { lock in
                if let info = try? VPhoneRestoreInfo.recordVariant(variant, toBundle: bundle, holding: lock, guestEnvironment: guestEnvironment),
                   info.variant != nil {
                    print("[cfw] recorded variant \(variant), device \(info.device ?? "?")")
                }
                if !keepArtifacts,
                   let removed = try? VPhoneRestoreInfo.removeBuiltFirmware(fromBundle: bundle, holding: lock) {
                    print("[cfw] removed built firmware \(removed)/ to save space (--keep-artifacts to keep)")
                }
            }
            if recorded == nil {
                FileHandle.standardError.write(Data(
                    "[cfw] Warning: skipped variant recording — the VM is busy (bundle lock held)\n".utf8))
            }
        }
        return code
    }
}

// MARK: - CFW frozen context

struct VPhoneCFWFrozenContext: Encodable {
    let schemaVersion = 1
    let vmDirectory: String
    let identity: VPhoneFirmwareIdentity
    let generationID: String
    let catalogSHA256: String
    let planSHA256: String
    let upstreamTarget: String
    let variant: String
    let verifierPath: String
    let verifierSHA256: String
    let guestEnvironment: String
    let spoofBuild: String
    let disableLaunchdHook: String
    let rawSHA256: String
    let enableFrida: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion, vmDirectory, identity, generationID, catalogSHA256, planSHA256,
             upstreamTarget, variant, verifierPath, verifierSHA256, guestEnvironment, spoofBuild, disableLaunchdHook
    }
    var json: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }
    var environment: [String: String] {
        get throws {
            ["VPHONE_FROZEN_PLAN": URL(fileURLWithPath: vmDirectory).appendingPathComponent(FirmwareDesiredPlanStore.filename).path,
             "VPHONE_FROZEN_PLAN_SHA256": rawSHA256, "VPHONE_FROZEN_CONTEXT": try json,
             "VPHONE_CFW_VARIANT": variant, "VPHONE_GUEST_ENVIRONMENT": guestEnvironment,
             "VPHONE_FRIDA": enableFrida ? "1" : "0", "DISABLE_LAUNCHD_HOOK": disableLaunchdHook,
             "SPOOF_BUILD": spoofBuild]
        }
    }
    static func prepare(in directory: URL, requestedVariant: String?, guestEnvironment: String, spoofBuild: String) throws -> Self {
        guard case .ready(let record) = try FirmwareDesiredPlanStore.read(in: directory) else {
            throw ValidationError("CFW requires a current bound desired plan; missing/legacy selection cannot authorize installation")
        }
        guard ["regular", "dev", "jb", "exp"].contains(record.plan.variant),
              requestedVariant == nil || requestedVariant == record.plan.variant else {
            throw ValidationError("CFW variant differs from frozen desired plan")
        }
        guard (record.plan.gates.guestEnvironmentV2 == true) == (guestEnvironment == "v2"),
              record.plan.gates.guestEnvironmentV2 != nil else {
            throw ValidationError("guest environment differs from frozen plan; legacy nil gates cannot authorize CFW")
        }
        guard spoofBuild.isEmpty || record.plan.variant == "exp" else {
            throw ValidationError("build-version rewrite requires EXP")
        }
        let hook = ProcessInfo.processInfo.environment["DISABLE_LAUNCHD_HOOK"] ?? "0"
        guard ["0", "1"].contains(hook) else { throw ValidationError("invalid DISABLE_LAUNCHD_HOOK") }
        let verifier = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let digest = SHA256.hash(data: try Data(contentsOf: verifier)).map { String(format: "%02x", $0) }.joined()
        return Self(vmDirectory: directory.standardizedFileURL.resolvingSymlinksInPath().path,
            identity: record.identity, generationID: record.generationID, catalogSHA256: record.catalogSHA256,
            planSHA256: record.planSHA256, upstreamTarget: record.upstreamTarget, variant: record.plan.variant,
            verifierPath: verifier.path, verifierSHA256: digest, guestEnvironment: guestEnvironment,
            spoofBuild: spoofBuild, disableLaunchdHook: hook, rawSHA256: try record.sha256,
            enableFrida: record.plan.gates.enableFrida)
    }
}

/// Read-only revalidation under the host driver's inherited VM lock. It deliberately
/// does not reacquire that flock in a child process. This command never grants writes.
struct VPhoneCFWVerifyPlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify-plan", shouldDisplay: false)
    @Argument var vmDirectory: String
    @Option var expectedSha256: String
    func run() throws {
        let directory = URL(fileURLWithPath: vmDirectory, isDirectory: true)
        guard case .ready(let record) = try FirmwareDesiredPlanStore.read(in: directory),
              try record.sha256 == expectedSha256 else {
            throw ValidationError("current frozen desired plan missing or changed")
        }
        struct Export: Encodable {
            let schemaVersion = 1
            let state = "ready"
            let rawSHA256: String
            let record: FirmwareDesiredPlanStore.Record
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(Export(rawSHA256: expectedSha256, record: record)), as: UTF8.self))
    }
}

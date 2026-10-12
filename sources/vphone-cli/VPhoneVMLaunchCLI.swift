import ArgumentParser
import Foundation
import VPhoneCore
import VPhoneBundleStore

struct VPhoneVMLaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch", abstract: "Boot a VM bundle (runs host preflight first)")

    @Option(help: .hidden) var expectedBindingSha256: String?
    @Option(help: .hidden) var expectedCoreBundle: String?
    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Boot into DFU mode (headless)") var dfu = false
    @Flag(name: .customLong("headless"), help: "Boot without a VM window or menu bar") var headless = false
    @Option(name: [.customShort("V"), .long], help: "Firmware variant") var variant: String?
    @Flag(name: .customLong("no-vphoned"), help: "Do not stage/use vphoned") var noVphoned = false
    @Option(help: "Expose candidate guest API on 127.0.0.1:PORT; requires VPHONE_API_TOKEN")
    var apiListen: String?
    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned; valid: 6000...65535)")
    var kernelDebugPort: Int?
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func guestPayloadArguments(resources: VPhoneResources) -> [String] {
        guard !dfu && !noVphoned else { return [] }
        let payload = variant == "less" ? resources.vphonedLess : resources.vphoned
        return ["--vphoned-bin", payload.path]
    }

    func apiProxyArguments() -> [String] {
        apiListen.map { ["--api-listen", $0] } ?? []
    }

    mutating func validate() throws {
        try VPhoneAPIProxyOptions.validate(listen: apiListen, dfu: dfu, noVphoned: noVphoned)
    }

    func run() throws {
        _ = try VPhoneAPIProxyOptions.resolve(listen: apiListen)
        let v = VPhoneVerbosity(count: verboseCount)
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        if bundle.manifest.usesStartupUnlock && !dfu && apiListen == nil {
            throw ValidationError("This VM enables startup unlock; supply --api-listen and VPHONE_API_TOKEN, or disable it with vm config --startup-unlock off.")
        }
        let machine = bundle.url
        let binding = try VPhoneMachineBinding.snapshot(machine)
        try validateExpectedBinding(binding)
        if let binding {
            guard projectRoot == nil else { throw ValidationError("A bound VM uses its verified Core Bundle resources; --project-root is refused.") }
            guard VPhoneCoreBundleVersion.supportsTargetFeatures(binding.binding.bundle) else {
                throw ValidationError("Bound VM execution requires Core Bundle 2.6.0 or later; select and verify a compatible bundle with vm bind-core-bundle.")
            }
            return try VPhoneCoreBundleStore().withVerifiedExecutable(version: binding.binding.bundle, executable: .vm) { binary in
                try Self.validateBoundLaunchProtocol(binary: binary)
                try launch(bundle: bundle, name: name, v: v, bootBinary: binary,
                    resources: .resolve(executablePath: binary.path), binding: binding, machine: machine)
            }
        }
        try launch(bundle: bundle, name: name, v: v, bootBinary: VPhoneResources.vmExecutable(),
            resources: projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve(),
            binding: nil, machine: machine)
    }

    func validateExpectedBinding(_ snapshot: VPhoneMachineBinding.Snapshot?) throws {
        guard expectedBindingSha256 != nil || expectedCoreBundle != nil else { return }
        guard let hash = expectedBindingSha256, hash.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let expectedCoreBundle, let snapshot,
              snapshot.sha256 == hash, snapshot.binding.bundle == expectedCoreBundle else {
            throw ValidationError("VM binding differs from the launcher's frozen selection; no VM was started.")
        }
    }

    // The store has already checked ownership, receipt and signatures. The
    // sealed marker identifies our guarded VM entry, rather than inferring
    // support from a release version or executing an unknown VM to probe it.
    static func validateBoundLaunchProtocol(binary: URL) throws {
        let info = binary.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any]
        guard values?["VPhoneBoundLaunchProtocol"] as? String == "vphone.local-bound-launch.v1" else {
            throw ValidationError("The selected Core Bundle VM does not declare the protected local launch protocol; no VM was started.")
        }
    }

    private func launch(bundle: VPhoneBundle, name: String, v: VPhoneVerbosity, bootBinary: URL,
                        resources: VPhoneResources, binding: VPhoneMachineBinding.Snapshot?,
                        machine: URL) throws {
        let layout = VPhoneLaunchLayout(resources: resources)
        guard FileManager.default.isExecutableFile(atPath: bootBinary.path) else {
            FileHandle.standardError.write(Data(
                "error: \(bootBinary.path) not found — build it first (make build/bundle).\n".utf8))
            throw ExitCode(1)
        }

        // Keep the existing environment key, but check the actual VM executable.
        var preflightArgs = ["--assert-bootable"]
        if variant == "less" { preflightArgs.append("--less") }
        var preflightEnv = ProcessInfo.processInfo.environment
        preflightEnv["VPHONE_CLI_BIN"] = bootBinary.path
        let pre = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/zsh"), [layout.preflightScript.path] + preflightArgs,
            cwd: resources.base, env: preflightEnv)
        // The preflight report is host diagnostics. Print it only when the VM
        // executable fails to start or run (here, or after the child exits);
        // a normal stop must not repeat it.
        let hostDiagnostics = pre.stdout
        guard pre.succeeded else {
            Self.printHostDiagnostics(hostDiagnostics)
            FileHandle.standardError.write(Data(pre.stderr.utf8))
            throw ExitCode(pre.exitCode == 0 ? 1 : pre.exitCode)
        }

        if binding == nil && !dfu && !noVphoned {
            // Staging is separate from the child boot lifetime. The child takes
            // its own lock and fails safely if another launch wins the gap.
            try VPhoneBundleGuard.withBundleLock(
                directory: bundle.url, operation: VPhoneVMOperation.stageVphoned
            ) { _ in
                do {
                    _ = try layout.stageVphoned(into: bundle, less: variant == "less")
                } catch {
                    FileHandle.standardError.write(Data(
                        "warning: could not stage vphoned into \(bundle.name): \(error)\n".utf8))
                }
            }
        }

        var args = ["--config", bundle.configURL.path] + (binding == nil ? guestPayloadArguments(resources: resources) : ["--no-vphoned-update"]) + apiProxyArguments()
        if bundle.manifest.usesStartupUnlock && !dfu { args.append("--unlock-at-startup") }
        if let binding {
            guard binding.matches(machine) else { throw ValidationError("VM binding changed during launch; no VM was started.") }
            args += ["--binding-sha256", binding.sha256]
        }
        if dfu { args.append("--dfu") }
        if headless { args.append("--headless") }
        if let variant { args += ["--variant", variant] }
        if noVphoned { args.append("--no-vphoned") }
        if let kernelDebugPort { args += ["--kernel-debug-port", String(kernelDebugPort)] }

        if v.tracesInternals {
            print("[trace] spawning: \(bootBinary.path) \(args.joined(separator: " "))")
        }

        let child = Process()
        child.executableURL = bootBinary
        child.arguments = args
        child.currentDirectoryURL = bundle.url
        // `vm launch` always streams the guest serial console (inherits our
        // stdio); it is intentionally not gated on verbosity. Flush our own
        // buffered stdout first so it stays ahead of the child's output when
        // stdout is a file or pipe.
        fflush(stdout)
        do {
            try child.run()
        } catch {
            Self.printHostDiagnostics(hostDiagnostics)
            throw error
        }

        // The ordinary launcher forwards these stop signals to this wrapper.
        // Convert each to the VM's graceful SIGINT path and keep waiting so
        // the store lock and output descriptors outlive the VM child.
        let stopSources = [SIGINT, SIGTERM, SIGHUP, SIGQUIT].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            signal(number, SIG_IGN)
            source.setEventHandler { child.interrupt() }
            source.resume()
            return source
        }
        defer { stopSources.forEach { $0.cancel() } }

        child.waitUntilExit()
        if Self.childFailed(reason: child.terminationReason, status: child.terminationStatus) {
            Self.printHostDiagnostics(hostDiagnostics)
        }
        throw ExitCode(child.terminationStatus)
    }

    // MARK: - Host diagnostics

    /// A normal stop (SIGINT/`vm stop` → `Guest stopped`) exits 0. A non-zero
    /// exit (for example AMFI's 137) or termination by a signal counts as a
    /// failure to start or run, and gets the preflight report.
    static func childFailed(reason: Process.TerminationReason, status: Int32) -> Bool {
        !(reason == .exit && status == 0)
    }

    static func printHostDiagnostics(_ text: String) {
        guard !text.isEmpty else { return }
        print(text, terminator: "")
        fflush(stdout)
    }
}

// MARK: - vm stop

struct VPhoneVMStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop a running VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    /// Default comes from `VPhoneShutdownPolicy`: the boot process answers
    /// SIGINT by asking the guest to power off, waits
    /// `VPhoneShutdownPolicy.gracefulTimeout` for it, then force-stops the VM
    /// through the framework and exits. This timeout must stay above that
    /// wait plus the force-stop margin, otherwise the SIGKILL below would land
    /// mid-teardown and produce exactly the abrupt exit the graceful path
    /// exists to avoid.
    @Option(name: .shortAndLong, help: "Seconds to wait for graceful shutdown before SIGKILL")
    var timeout: Int = VPhoneShutdownPolicy.defaultStopTimeout
    @Flag(help: "Skip graceful shutdown and SIGKILL; refuses while a guest write operation is active")
    var force = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)

        // All target selection, signalling and confirmation lives in
        // VPhoneVMStopper; this command only formats its progress and outcome.
        let stopper = VPhoneVMStopper(
            bundleDirectory: bundle.url, configURL: bundle.configURL,
            diskURL: bundle.url.appendingPathComponent(bundle.manifest.diskImage),
            report: { event in
                switch event {
                case let .bootInstance(id):
                    print("\(name): boot instance \(id)")
                case let .signalling(pids):
                    print("\(name): sending SIGINT to \(Self.list(pids))")
                case let .forceKilling(pids):
                    print("\(name): force-killing \(Self.list(pids))")
                }
            })

        let outcome = stopper.stop(timeout: TimeInterval(timeout), force: force)
        switch outcome {
        case .notRunning:
            print("\(name): not running")

        case let .noBootTarget(detail):
            FileHandle.standardError.write(Data(
                "error: \(name): bundle lock is held but \(detail) — not signalling anything\n".utf8))

        case .stopped:
            print("\(name): stopped")

        case let .failed(_, reason):
            FileHandle.standardError.write(Data("error: \(name): stop failed: \(reason)\n".utf8))
        }
        if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }

    private static func list(_ pids: [Int32]) -> String {
        pids.map(String.init).joined(separator: ", ")
    }
}

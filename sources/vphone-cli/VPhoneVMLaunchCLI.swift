import ArgumentParser
import Foundation
import VPhoneCore

struct VPhoneVMLaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch", abstract: "Boot a VM bundle (runs host preflight first)")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Boot into DFU mode (headless)") var dfu = false
    @Flag(name: .customLong("headless"), help: "Boot without a VM window or menu bar") var headless = false
    @Option(name: [.customShort("V"), .long], help: "Firmware variant") var variant: String?
    @Flag(name: .customLong("no-vphoned"), help: "Do not stage/use vphoned") var noVphoned = false
    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned; valid: 6000...65535)")
    var kernelDebugPort: Int?
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let v = VPhoneVerbosity(count: verboseCount)
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let layout = VPhoneLaunchLayout(resources: resources)

        // The running executable is BOTH what we boot from and what preflight
        // should check — a bundled .app is its own boot binary.
        let bootBinary = VPhoneResources.runningExecutable()
        guard FileManager.default.isExecutableFile(atPath: bootBinary.path) else {
            FileHandle.standardError.write(Data(
                "error: \(bootBinary.path) not found — build it first (make build/bundle).\n".utf8))
            throw ExitCode(1)
        }

        // Host preflight — same gate make boot applies. Point it at THIS binary
        // (VPHONE_CLI_BIN) so it checks the vphone-cli we're running, not a dev
        // .build/release path that doesn't exist inside the bundled .app.
        var preflightArgs = ["--assert-bootable"]
        if variant == "less" { preflightArgs.append("--less") }
        var preflightEnv = ProcessInfo.processInfo.environment
        preflightEnv["VPHONE_CLI_BIN"] = bootBinary.path
        let pre = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/zsh"), [layout.preflightScript.path] + preflightArgs,
            cwd: resources.base, env: preflightEnv)
        if !pre.stdout.isEmpty { print(pre.stdout, terminator: "") }
        guard pre.succeeded else {
            FileHandle.standardError.write(Data(pre.stderr.utf8))
            throw ExitCode(pre.exitCode == 0 ? 1 : pre.exitCode)
        }

        if !dfu && !noVphoned {
            // Staging is separate from the child boot lifetime. The child takes
            // its own lock and fails safely if another launch wins the gap.
            try VPhoneBundleGuard.withBundleLock(
                directory: bundle.url, operation: VPhoneVMOperation.stageVphoned
            ) { _ in
                do {
                    _ = try layout.stageVphoned(into: bundle)
                } catch {
                    FileHandle.standardError.write(Data(
                        "warning: could not stage vphoned into \(bundle.name): \(error)\n".utf8))
                }
            }
        }

        var args = ["--config", bundle.configURL.path]
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
        // stdio); it is intentionally not gated on verbosity.
        try child.run()

        // Forward SIGINT to the child so Ctrl+C stops the VM cleanly.
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigint.setEventHandler { child.interrupt() }
        sigint.resume()

        child.waitUntilExit()
        throw ExitCode(child.terminationStatus)
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
    @Flag(help: "Skip the graceful shutdown request and SIGKILL the boot process immediately")
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

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
            let stagingLock = try VPhoneVMLock(directory: bundle.url, operation: "stage-vphoned")
            defer { withExtendedLifetime(stagingLock) {} }
            do {
                _ = try layout.stageVphoned(into: bundle)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: could not stage vphoned into \(bundle.name): \(error)\n".utf8))
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

    /// PIDs of vphone-cli processes booted against this bundle's config.
    ///
    /// Deliberately NOT `lsof Disk.img`: the disk image is held open by the
    /// Virtualization.framework helper process, so signalling the file holder
    /// tears the VM out from under vphone-cli (`VZErrorDomain Code=1`) instead
    /// of letting its SIGINT handler shut down.
    private static func bootPIDs(configURL: URL) -> [Int32] {
        guard let ps = try? VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="]) else { return [] }
        return VPhoneBootProcessLocator.parsePIDs(ps.stdout, configURL: configURL)
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        // ESRCH is the only "gone" answer; EPERM still means the pid exists.
        kill(pid, 0) == 0 || errno != ESRCH
    }

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)

        // The kernel flock on the bundle directory is the authoritative liveness
        // signal; the runtime record is only a hint.
        guard VPhoneVMLockProbe.isLockHeld(directory: bundle.url) else {
            print("\(name): not running")
            return
        }

        let targets = Self.bootPIDs(configURL: bundle.configURL)
        // The runtime record is only corroborating evidence: a recorded boot pid
        // counts as a target solely when ps confirms it is a vphone-cli --config
        // process for THIS bundle (a stale record may name a reused pid), and
        // such a pid is already in `targets`. So the record never adds a target;
        // below it only explains who holds the lock when no target was found.
        guard !targets.isEmpty else {
            var detail = "no vphone-cli boot process is running for it"
            if let record = VPhoneVMRuntimeState.read(in: bundle.url), Self.isAlive(record.pid) {
                detail = "it is held by pid \(record.pid) running operation \"\(record.operation)\""
            }
            FileHandle.standardError.write(Data(
                "error: \(name): bundle lock is held but \(detail) — not signalling anything\n".utf8))
            throw ExitCode(1)
        }

        if force {
            print("\(name): force-killing \(targets.map(String.init).joined(separator: ", "))")
            for pid in targets { kill(pid, SIGKILL) }
            print("\(name): stopped")
            return
        }

        print("\(name): sending SIGINT to \(targets.map(String.init).joined(separator: ", "))")
        for pid in targets { kill(pid, SIGINT) }

        var waited = 0
        while waited < timeout, targets.contains(where: Self.isAlive) {
            Thread.sleep(forTimeInterval: 1)
            waited += 1
        }
        let survivors = targets.filter(Self.isAlive)
        if !survivors.isEmpty {
            print("\(name): force-killing \(survivors.map(String.init).joined(separator: ", "))")
            for pid in survivors { kill(pid, SIGKILL) }
        }
        print("\(name): stopped")
    }
}

import AppKit
import Foundation
import Virtualization
import VPhoneCore
import VPhoneAPIKit

// MARK: - Exit status

/// Status the process exits with once `applicationWillTerminate` has run its
/// cleanup. Exit paths terminate through AppKit (so the host bridge socket and
/// the host sleep activity are released) and record a non-zero status here
/// instead of calling `exit` directly.
@MainActor
enum VPhoneExitStatus {
    static var pending: Int32 = EXIT_SUCCESS

    /// Terminate the app from a `nonisolated` context (VM delegate callbacks).
    nonisolated static func terminate(status: Int32) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                pending = status
                NSApp.terminate(nil)
            }
        }
    }
}

@MainActor
class VPhoneAppDelegate: NSObject, NSApplicationDelegate {
    private var vmLock: VPhoneVMLock?
    private(set) var guestWrites = VPhoneGuestWriteCoordinator()
    private var stopWaitingForWriter = false
    private let cli: VPhoneBootCLI
    private var vm: VPhoneVirtualMachine?
    private var control: VPhoneControl?
    private var windowController: VPhoneWindowController?
    private var menuController: VPhoneMenuController?
    private var fileWindowController: VPhoneFileWindowController?
    private var keychainWindowController: VPhoneKeychainWindowController?
    private var appWindowController: VPhoneAppWindowController?
    private var locationProvider: VPhoneLocationProvider?
    private var hostControl: VPhoneHostControl?
    private var apiProxy: VPhoneAPIProxy?
    private var apiSession: VPhoneAPISession?
    private var shutdownConnector: VPhoneAPIProxy.Connector?
    private var startupUnlock: VPhoneStartupUnlock?
    private let hostInputQueue = VPhoneHostInputQueue()
    private var cameraServer: VPhoneCameraServer?
    private var shutdownSignals: VPhoneShutdownSignals?
    private var hostSleepActivity: NSObjectProtocol?
    private var didAttemptAutoInstall = false
    private var shutdownPlan = VPhoneShutdownPlan()
    private var shutdownTimeoutTask: Task<Void, Never>?
    private var guestShutdownTask: Task<Void, Never>?

    init(cli: VPhoneBootCLI) {
        self.cli = cli
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(cli.noGraphics ? .prohibited : .regular)

        shutdownSignals = VPhoneShutdownSignals { [weak self] number in
            print("\n[vphone] \(VPhoneChildCancellation.name(of: number)) — shutting down")
            self?.handleInterrupt()
        }

        Task { @MainActor in
            do {
                try await self.startVirtualMachine()
            } catch {
                print("[vphone] Fatal: \(error)")
                VPhoneExitStatus.pending = EXIT_FAILURE
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor
    private func startVirtualMachine() async throws {
        let apiOptions = try VPhoneAPIProxyOptions.resolve(listen: cli.apiListen)
        // Acquire before reading or mutating the manifest and opening VM storage.
        vmLock = try VPhoneVMLock(directory: cli.config.resolvingSymlinksInPath().deletingLastPathComponent(),
                                  operation: cli.dfu
                                      ? VPhoneVMOperation.dfu
                                      : VPhoneVMOperation.boot)
        if let digest = cli.bindingSha256 {
            let directory = cli.config.resolvingSymlinksInPath().deletingLastPathComponent()
            let machine = directory
            guard let binding = try VPhoneMachineBinding.snapshot(machine), binding.sha256 == digest else {
                throw VPhoneMachineBindingError("VM binding differs from the launch selection; no VM was started")
            }
        }
        guestWrites = VPhoneGuestWriteCoordinator(directory: cli.config.resolvingSymlinksInPath().deletingLastPathComponent())
        FileHandle.standardOutput.write(Data("[vphone] VM lock acquired\n".utf8))
        let options = try cli.resolveOptions()

        guard options.romURL == nil || FileManager.default.fileExists(atPath: options.romURL!.path) else {
            throw VPhoneError.romNotFound(options.romURL!.path)
        }

        print("=== vphone-cli ===")
        print("Variant : \(options.variant)")
        print("ROM     : \(options.romURL?.path ?? "None")")
        print("Disk    : \(options.diskURL.path)")
        print("NVRAM   : \(options.nvramURL.path)")
        print("Config  : \(options.configURL.path)")
        print("CPU     : \(options.cpuCount)")
        print("Memory  : \(options.memorySize / 1024 / 1024) MB")
        print(
            "Screen: \(options.screenWidth)x\(options.screenHeight) @ \(options.screenPPI) PPI (scale \(options.screenScale)x)"
        )
        if let kernelDebugPort = options.kernelDebugPort {
            print("Kernel debug stub : 127.0.0.1:\(kernelDebugPort)")
        } else {
            print("Kernel debug stub : auto-assigned")
        }
        print("SEP               : enabled")
        print("  storage         : \(options.sepStorageURL.path)")
        print("  rom             : \(options.sepRomURL?.path ?? "None")")
        print("")

        let vm = try VPhoneVirtualMachine(options: options)
        self.vm = vm

        try await vm.start(forceDFU: cli.dfu)
        if !cli.allowHostIdleSleep {
            hostSleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Keep the vPhone virtual machine running"
            )
            print("[vphone] Host idle system sleep disabled while VM is running")
        }

        let control = VPhoneControl(variant: options.variant)
        self.control = control
        control.guestWrites = guestWrites
        if !cli.dfu {
            if let vphonedURL = cli.autoUpdateGuestBinaryURL, FileManager.default.fileExists(atPath: vphonedURL.path) {
                control.guestBinaryURL = vphonedURL
            }

            let provider = VPhoneLocationProvider(
                control: control,
                locationStateURL: options.configURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("system-location.json"))
            locationProvider = provider

            let camServer = VPhoneCameraServer()
            cameraServer = camServer

            if let device = vm.virtualMachine.socketDevices.first as? VZVirtioSocketDevice {
                shutdownConnector = VPhoneAPIVSockConnector.make(device: device)
                if let apiOptions {
                    let proxy = try VPhoneAPIProxy(token: apiOptions.token, connector: VPhoneAPIVSockConnector.make(device: device))
                    let url = try proxy.start(port: apiOptions.port)
                    apiProxy = proxy
                    if let vmLock {
                        let session = VPhoneAPISession(
                            // The guest permits screen.unlock to run for 60 s.
                            // Keep health probes short without timing out that RPC first.
                            client: try VPhoneAPIClient(baseURL: url, token: proxy.internalToken, timeout: 5, rpcTimeout: 75),
                            vmInstanceID: vmLock.state.instanceID)
                        apiSession = session
                        let persistedUnlock = try VPhoneVirtualMachineManifest.load(from: options.configURL).usesStartupUnlock
                        let unlock = VPhoneStartupUnlock(enabled: cli.unlockAtStartup || persistedUnlock) { [weak session, hostInputQueue] method, params, capability in
                            guard let session else { throw CancellationError() }
                            let result: Result<VPhoneJSONValue, any Error> = await hostInputQueue.run(cancelled: .failure(CancellationError())) {
                                do { return .success(try await session.call(method, params: params, requiring: capability)) }
                                catch { return .failure(error) }
                            }
                            return try result.get()
                        }
                        startupUnlock = unlock
                        session.onSnapshotChange = { [weak unlock, weak session, weak self] snapshot in
                            unlock?.observe(snapshot)
                            if snapshot.state == .ready { Task { await self?.guestWrites.reconcile(session) } }
                        }
                        session.start()
                    }
                    print("[api] proxy listening on \(url.absoluteString); guest VSOCK 1339; token from VPHONE_API_TOKEN")
                }
                control.connect(device: device)
                camServer.connect(device: device)
            }
        }

        var hostScreen: (any VPhoneHostScreen)?
        if !cli.noGraphics {
            let keyHelper = VPhoneKeyHelper(vm: vm, control: control)
            let wc = makeWindowController()
            wc.showWindow(
                for: vm.virtualMachine,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight,
                screenScale: options.screenScale,
                keyHelper: keyHelper,
                control: control,
                ecid: vm.ecidHex, inputQueue: hostInputQueue
            )
            windowController = wc

            let fileWC = VPhoneFileWindowController()
            fileWindowController = fileWC

            let keychainWC = VPhoneKeychainWindowController()
            keychainWindowController = keychainWC

            let appWC = VPhoneAppWindowController()
            appWindowController = appWC

            let mc = VPhoneMenuController(keyHelper: keyHelper, control: control)
            mc.onStop = { [weak self] in self?.handleInterrupt() }
            mc.startupUnlockItem?.isEnabled = startupUnlock != nil
            let savedStartupUnlock = try VPhoneVirtualMachineManifest.load(from: options.configURL).usesStartupUnlock
            mc.startupUnlockItem?.state = (cli.unlockAtStartup || savedStartupUnlock) ? .on : .off
            mc.onStartupUnlockChanged = { [weak self] enabled in
                guard let self, self.vmLock != nil, let unlock = self.startupUnlock else { throw VPhoneMachineBindingError("Startup unlock requires an API listener") }
                let manifest = try VPhoneVirtualMachineManifest.load(from: options.configURL)
                try manifest.updating(unlockAtStartup: enabled).write(to: options.configURL)
                unlock.setEnabled(enabled)
            }
            mc.onManualUnlock = { [weak self] in
                guard let self, let session = self.apiSession else { return }
                Task { @MainActor in
                    let failure: String? = await self.hostInputQueue.run(cancelled: "Unlock cancelled") {
                        do { _ = try await session.call("screen.unlock", params: ["timeout": .number(60)], requiring: "screen_unlock"); return nil }
                        catch { return error.localizedDescription }
                    }
                    if let failure { let alert = NSAlert(); alert.messageText = "Screen unlock failed"; alert.informativeText = failure; alert.runModal() }
                }
            }
            if let session = apiSession {
                let unlock = startupUnlock
                session.onSnapshotChange = { [weak mc, weak unlock, weak session, weak self] snapshot in
                    if snapshot.state == .ready { Task { await self?.guestWrites.reconcile(session) } }
                    unlock?.observe(snapshot)
                    mc?.manualUnlockItem?.isEnabled = snapshot.state == .ready && snapshot.health?.capabilities.contains("screen_unlock") == true
                }
                mc.manualUnlockItem?.isEnabled = session.snapshot.state == .ready && session.snapshot.health?.capabilities.contains("screen_unlock") == true
            }
            mc.vm = vm
            mc.captureView = wc.captureView
            mc.touchIDMonitor = wc.touchIDMonitor
            mc.onFilesPressed = { [weak fileWC, weak control] in
                guard let fileWC, let control else { return }
                fileWC.showWindow(control: control)
            }
            mc.onKeychainPressed = { [weak keychainWC, weak control] in
                guard let keychainWC, let control else { return }
                keychainWC.showWindow(control: control)
            }
            mc.onAppsPressed = { [weak appWC, weak control] in
                guard let appWC, let control else { return }
                appWC.showWindow(control: control)
            }
            if let provider = locationProvider {
                mc.locationProvider = provider
            }
            if let camServer = cameraServer {
                mc.cameraServer = camServer
                camServer.onConnectionStateChange = { [weak mc] connected in
                    Task { @MainActor in
                        mc?.updateCameraConnectionState(connected: connected)
                    }
                }
            }
            let recorder = VPhoneScreenRecorder()
            mc.screenRecorder = recorder
            menuController = mc

            hostScreen = VPhoneHostScreenAdapter(
                view: wc.captureView!, recorder: recorder,
                width: options.screenWidth, height: options.screenHeight)

            // Wire location toggle through onConnect/onDisconnect
            control.onConnect = { [weak mc, weak provider = locationProvider] caps in
                mc?.updateConnectAvailability(available: true)
                mc?.updateInstallAvailability(available: caps.contains("ipa_install"))
                mc?.updateAppsAvailability(available: caps.contains("apps"))
                mc?.updateURLAvailability(available: caps.contains("url"))
                mc?.updateClipboardAvailability(available: caps.contains("clipboard"))
                mc?.updateSettingsAvailability(available: true)
                mc?.updateShellAvailability(available: caps.contains("shell"))
                if caps.contains("location") {
                    mc?.updateLocationCapability(available: true)
                    if provider?.externallyControlled == true {
                        Task { @MainActor in
                            await provider?.systemLocationController.reapplyAfterReconnect()
                        }
                    }
                    // Auto-resume if user had toggle on — unless the UDS surface
                    // has taken ownership of the location source, in which case
                    // resuming would clobber the externally injected fix.
                    if mc?.locationMenuItem?.state == .on,
                       provider?.externallyControlled != true {
                        provider?.startForwarding()
                    }
                } else {
                    print("[location] guest does not support location simulation")
                }
                mc?.syncBatteryFromHost()
                mc?.syncLowPowerModeFromHost()
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak mc, weak provider = locationProvider] in
                mc?.updateConnectAvailability(available: false)
                mc?.updateInstallAvailability(available: false)
                mc?.updateAppsAvailability(available: false)
                mc?.updateURLAvailability(available: false)
                mc?.updateClipboardAvailability(available: false)
                mc?.updateSettingsAvailability(available: false)
                mc?.updateShellAvailability(available: false)
                provider?.stopReplay()
                provider?.stopForwarding()
                mc?.updateLocationCapability(available: false)
            }
        } else if !cli.dfu {
            // Headless mode: auto-start location as before (no menu exists) —
            // but not once the UDS surface owns the source, else every reconnect
            // would overwrite the externally injected fix with Mac forwarding.
            control.onConnect = { [weak provider = locationProvider] caps in
                if caps.contains("location") {
                    if provider?.externallyControlled == true {
                        Task { @MainActor in
                            await provider?.systemLocationController.reapplyAfterReconnect()
                        }
                    }
                    if provider?.externallyControlled != true {
                        provider?.startForwarding()
                    }
                } else {
                    print("[location] guest does not support location simulation")
                }
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak provider = locationProvider] in
                provider?.stopReplay()
                provider?.stopForwarding()
            }
        }

        // Ordinary GUI/headless VMs share one control lifetime. DFU exposes only
        // discovery: vphoned and its guest capabilities are not running there.
        let executor = VPhoneHostCommandExecutor(
            control: control, camera: cameraServer, location: locationProvider,
            screen: hostScreen, apiSession: apiSession, bootMode: cli.dfu ? .dfu : .normal,
            target: vmLock.map { VPhoneHostTarget(lock: $0.state) }, inputQueue: hostInputQueue, guestWrites: guestWrites, runtime: vmLock)
        let hc = VPhoneHostControl(
            socketPath: options.configURL.deletingLastPathComponent()
                .appendingPathComponent("vphone.sock").path,
            executor: executor)
        hostControl = hc
        try hc.start()

    }

    @MainActor
    private func installPackageIfRequested(caps: [String]) async {
        guard !didAttemptAutoInstall else { return }
        guard let packageURL = cli.installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            didAttemptAutoInstall = true
            print("[install] requested package not found: \(packageURL.path)")
            return
        }
        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            didAttemptAutoInstall = true
            print("[install] unsupported package type: \(packageURL.path)")
            return
        }
        guard caps.contains("ipa_install") else {
            print(
                "[install] guest does not advertise ipa_install; reconnect or reboot the guest so the updated daemon can take over"
            )
            return
        }
        guard let control else {
            print("[install] control channel is not ready")
            return
        }

        didAttemptAutoInstall = true
        print("[install] auto-installing \(packageURL.lastPathComponent)")
        do {
            let result = try await control.installIPA(localURL: packageURL)
            print("[install] \(result)")
        } catch {
            print("[install] failed: \(error)")
        }
    }

    // MARK: - Shutdown

    func makeWindowController() -> VPhoneWindowController {
        let controller = VPhoneWindowController()
        controller.onCloseRequested = { [weak self] in self?.handleInterrupt() }
        return controller
    }

    @MainActor private var apiCanShutdown: Bool {
        apiSession?.snapshot.state == .ready && apiSession?.snapshot.health?.capabilities.contains("system_shutdown") == true
    }

    func guestAPIShutdownRequest(connector: VPhoneAPIProxy.Connector?) -> (() async throws -> Bool)? {
        guard !cli.dfu, !cli.noVphoned else { return nil }
        if apiCanShutdown {
            return { [weak self] in
                guard let session = self?.apiSession else { return false }
                let reply = try await session.call("system.shutdown", params: ["force": .bool(true)], requiring: "system_shutdown")
                if case let .object(fields) = reply { return fields["accepted"] == .bool(true) }
                return false
            }
        }
        guard let connector else { return nil }
        return {
            print("[vphone] guest shutdown via direct API VSOCK")
            return try await VPhoneAPIGuestShutdown(connector: connector).request()
        }
    }

    /// Ask the guest to power off, wait a bounded time for
    /// `guestDidStop`, then force-stop the VM through the framework so the
    /// teardown is the framework's and not this process dying.
    @MainActor
    private func handleInterrupt() {
        guard !stopWaitingForWriter else { return }
        stopWaitingForWriter = true
        if guestWrites.pendingRecovery { print("[vphone] Stop waits for pending guest recovery; query guest env status to reconcile") }
        Task { @MainActor in
            await guestWrites.sealAndWait()
            stopWaitingForWriter = false
            handleDrainedInterrupt()
        }
    }

    @MainActor
    func handleDrainedInterrupt() {
        startupUnlock?.stop()
        guard let vm else {
            NSApp.terminate(nil)
            return
        }
        if shutdownPlan.didStart {
            // Another shutdown request while waiting skips the remaining wait.
            print("[vphone] repeated shutdown request — stopping now")
            forceStopAndExit(action: shutdownPlan.abortWait())
            return
        }

        let api = guestAPIShutdownRequest(connector: shutdownConnector)
        let action = shutdownPlan.start(VPhoneShutdownPlan.Conditions(
            vmRunning: vm.isRunning,
            guestShellAvailable: api != nil || (control?.canHaltGuest ?? false),
            canRequestStop: vm.canRequestStop))

        switch action {
        case .exitImmediately:
            print("[vphone] VM is not running — exiting")
            NSApp.terminate(nil)
        case .guestCommand:
            print("[vphone] graceful shutdown via guest power-off command over vsock")
            startGracefulTimeout()
            guestShutdownTask = Task { @MainActor in
                let request = VPhoneGuestShutdown(api: api, classic: { [weak self] in
                    guard let self, !self.shutdownPlan.forceStopRequested else { return false }
                    return await self.control?.haltGuest() == true
                }, running: { [weak self] in self?.vm?.isRunning == true })
                let result = await request.request()
                print("[vphone] guest shutdown request: \(result); awaiting VM stop")
                if result == .frameworkRequired { self.fallBackFromGuestCommand(vm: vm) }
            }
        case .requestStop:
            print("[vphone] graceful shutdown via VZVirtualMachine.requestStop()")
            startGracefulTimeout()
            if !vm.requestGuestStop() {
                forceStopAndExit(action: shutdownPlan.gracefulAttemptFailed())
            }
        case .waitForStop:
            return
        case .forceStop:
            print("[vphone] no graceful shutdown path available; stopping")
            forceStopAndExit(action: action)
        }
    }

    /// The guest reported it has no power-off command: try the framework stop
    /// request, else force-stop. The graceful timer is already running.
    @MainActor
    private func fallBackFromGuestCommand(vm: VPhoneVirtualMachine) {
        guard !shutdownPlan.forceStopRequested, vm.isRunning else { return }
        if vm.canRequestStop {
            print("[vphone] graceful shutdown via VZVirtualMachine.requestStop()")
            if vm.requestGuestStop() { return }
        }
        forceStopAndExit(action: shutdownPlan.gracefulAttemptFailed())
    }

    @MainActor
    private func startGracefulTimeout() {
        shutdownTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(VPhoneShutdownPolicy.gracefulTimeout))
            guard !Task.isCancelled else { return }
            print("[vphone] graceful shutdown timed out; stopping")
            self.forceStopAndExit(action: self.shutdownPlan.abortWait())
        }
    }

    @MainActor
    private func forceStopAndExit(action: VPhoneShutdownPlan.Action) {
        guard action == .forceStop else { return }
        shutdownTimeoutTask?.cancel()
        shutdownTimeoutTask = nil
        guestShutdownTask?.cancel()
        guestShutdownTask = nil
        guard let vm else {
            NSApp.terminate(nil)
            return
        }
        Task { @MainActor in
            await vm.forceStop()
            print("[vphone] VM stopped")
            NSApp.terminate(nil)
        }
    }

    @MainActor
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard vm?.isRunning == true else { return .terminateNow }
        handleInterrupt()
        return .terminateCancel
    }

    func applicationWillTerminate(_: Notification) {
        guestShutdownTask?.cancel()
        shutdownConnector = nil
        startupUnlock?.stop()
        apiSession?.stop()
        apiProxy?.stop()
        hostControl?.stop()
        control?.close()
        if let hostSleepActivity {
            ProcessInfo.processInfo.endActivity(hostSleepActivity)
            self.hostSleepActivity = nil
        }
        // The VM delegate records a failure status before terminating; AppKit
        // would otherwise always exit 0.
        shutdownSignals = nil
        exit(VPhoneExitStatus.pending)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !cli.noGraphics
    }
}

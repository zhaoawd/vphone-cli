import AppKit
import Foundation
import Virtualization
import VPhoneCore

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

class VPhoneAppDelegate: NSObject, NSApplicationDelegate {
    private var vmLock: VPhoneVMLock?
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
    private var cameraServer: VPhoneCameraServer?
    private var sigintSource: DispatchSourceSignal?
    private var hostSleepActivity: NSObjectProtocol?
    private var didAttemptAutoInstall = false
    private var shutdownPlan = VPhoneShutdownPlan()
    private var shutdownTimeoutTask: Task<Void, Never>?

    init(cli: VPhoneBootCLI) {
        self.cli = cli
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(cli.noGraphics ? .prohibited : .regular)

        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { [weak self] in
            print("\n[vphone] SIGINT — shutting down")
            self?.handleInterrupt()
        }
        src.activate()
        sigintSource = src

        Task { @MainActor in
            do {
                try await self.startVirtualMachine()
            } catch {
                print("[vphone] Fatal: \(error)")
                exit(EXIT_FAILURE)
            }
        }
    }

    @MainActor
    private func startVirtualMachine() async throws {
        // Acquire before reading or mutating the manifest and opening VM storage.
        vmLock = try VPhoneVMLock(directory: cli.config.resolvingSymlinksInPath().deletingLastPathComponent(),
                                  operation: cli.dfu
                                      ? VPhoneVMOperation.dfu
                                      : VPhoneVMOperation.boot)
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
        if !cli.dfu {
            let vphonedURL = URL(fileURLWithPath: cli.vphonedBin)
            if FileManager.default.fileExists(atPath: vphonedURL.path) {
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
                control.connect(device: device)
                camServer.connect(device: device)
            }
        }

        if !cli.noGraphics {
            let keyHelper = VPhoneKeyHelper(vm: vm, control: control)
            let wc = VPhoneWindowController()
            wc.showWindow(
                for: vm.virtualMachine,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight,
                screenScale: options.screenScale,
                keyHelper: keyHelper,
                control: control,
                ecid: vm.ecidHex
            )
            windowController = wc

            let fileWC = VPhoneFileWindowController()
            fileWindowController = fileWC

            let keychainWC = VPhoneKeychainWindowController()
            keychainWindowController = keychainWC

            let appWC = VPhoneAppWindowController()
            appWindowController = appWC

            let mc = VPhoneMenuController(keyHelper: keyHelper, control: control)
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

            let socketPath = options.configURL
                .deletingLastPathComponent()
                .appendingPathComponent("vphone.sock").path
            let hc = VPhoneHostControl(socketPath: socketPath)
            hc.start(
                captureView: wc.captureView!,
                screenRecorder: recorder,
                control: control,
                cameraServer: cameraServer,
                locationProvider: locationProvider,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight
            )
            hostControl = hc

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

    /// SIGINT: ask the guest to power off, wait a bounded time for
    /// `guestDidStop`, then force-stop the VM through the framework so the
    /// teardown is the framework's and not this process dying.
    @MainActor
    private func handleInterrupt() {
        guard let vm else {
            NSApp.terminate(nil)
            return
        }
        if shutdownPlan.didStart {
            // Second SIGINT while waiting — skip the rest of the wait.
            print("[vphone] second SIGINT — stopping now")
            forceStopAndExit(action: shutdownPlan.abortWait())
            return
        }

        let action = shutdownPlan.start(VPhoneShutdownPlan.Conditions(
            vmRunning: vm.isRunning,
            guestShellAvailable: control?.canHaltGuest ?? false,
            canRequestStop: vm.canRequestStop))

        switch action {
        case .exitImmediately:
            print("[vphone] VM is not running — exiting")
            NSApp.terminate(nil)
        case .guestCommand:
            print("[vphone] graceful shutdown via guest power-off command over vsock")
            startGracefulTimeout()
            Task { @MainActor in
                if await self.control?.haltGuest() != true {
                    self.fallBackFromGuestCommand(vm: vm)
                }
            }
        case .requestStop:
            print("[vphone] graceful shutdown via VZVirtualMachine.requestStop()")
            startGracefulTimeout()
            if !vm.requestGuestStop() {
                forceStopAndExit(action: shutdownPlan.gracefulAttemptFailed())
            }
        case .forceStop:
            print("[vphone] no graceful shutdown path available; stopping")
            forceStopAndExit(action: action)
        }
    }

    /// The guest reported it has no power-off command: try the framework stop
    /// request, else force-stop. The graceful timer is already running.
    @MainActor
    private func fallBackFromGuestCommand(vm: VPhoneVirtualMachine) {
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

    func applicationWillTerminate(_: Notification) {
        hostControl?.stop()
        if let hostSleepActivity {
            ProcessInfo.processInfo.endActivity(hostSleepActivity)
            self.hostSleepActivity = nil
        }
        // The VM delegate records a failure status before terminating; AppKit
        // would otherwise always exit 0.
        exit(VPhoneExitStatus.pending)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !cli.noGraphics
    }
}

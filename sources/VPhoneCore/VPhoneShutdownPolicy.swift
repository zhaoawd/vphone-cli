import Foundation

// MARK: - Shutdown policy

/// Timeouts and the guest power-off command shared by the boot process (which
/// performs the shutdown) and `vm stop` (which triggers it with SIGINT).
public enum VPhoneShutdownPolicy {
    /// Seconds the boot process waits for the guest to power off by itself
    /// after the shutdown request, before force-stopping the VM.
    ///
    /// Measured on rig-baseline (iOS 26.6.1, exp variant): the guest reached
    /// `guestDidStop` about 3 s after the `halt` request. 10 s leaves room for
    /// a slower guest without stretching an interactive Ctrl+C.
    public static let gracefulTimeout: TimeInterval = 10

    /// Extra seconds `vm stop` allows on top of `gracefulTimeout` for the
    /// framework force stop and process exit that follow a timed-out wait.
    public static let stopMargin: TimeInterval = 10

    /// Default `vm stop --timeout`. Must stay above `gracefulTimeout`, else
    /// `vm stop` would SIGKILL the boot process while it is still shutting the
    /// VM down and the teardown would be the abrupt one it is meant to avoid.
    public static var defaultStopTimeout: Int {
        Int((gracefulTimeout + stopMargin).rounded(.up))
    }

    /// Guest command that powers the VM off, run through vphoned's `shell`
    /// (`/bin/sh -c`, root). The candidate list is ordered by where a power-off
    /// binary is found: procursus installs `halt` under `/var/jb` on jb/exp
    /// variants; the base iOS system in these VMs ships none of these paths, so
    /// the command exits `guestHaltUnsupportedExitCode` and the caller falls
    /// back to the framework stop request.
    public static let guestHaltCommand =
        #"for h in /var/jb/sbin/halt /sbin/halt /usr/sbin/halt; do [ -x "$h" ] && exec "$h"; done; exit 127"#

    /// Exit status `guestHaltCommand` reports when the guest has no power-off
    /// binary (`sh` convention for "command not found").
    public static let guestHaltUnsupportedExitCode = 127
}

// MARK: - Shutdown plan

/// Which shutdown mechanism to use, and what a repeated interrupt does. Pure
/// decision logic so it can be tested without a VM.
public struct VPhoneShutdownPlan: Sendable {
    /// What the boot process knows about the VM when the interrupt arrives.
    public struct Conditions: Sendable {
        public var vmRunning: Bool
        /// vphoned is connected and advertises the `shell` capability.
        public var guestShellAvailable: Bool
        /// `VZVirtualMachine.canRequestStop`.
        public var canRequestStop: Bool

        public init(vmRunning: Bool, guestShellAvailable: Bool, canRequestStop: Bool) {
            self.vmRunning = vmRunning
            self.guestShellAvailable = guestShellAvailable
            self.canRequestStop = canRequestStop
        }
    }

    public enum Action: Equatable, Sendable {
        /// Ask the guest OS to power itself off over vsock, then wait.
        case guestCommand
        /// `VZVirtualMachine.requestStop()`, then wait.
        case requestStop
        /// `VZVirtualMachine.stop(completionHandler:)` — no waiting.
        case forceStop
        /// Nothing is running; exit without touching the VM.
        case exitImmediately
    }

    /// True once `start` has chosen a graceful path, i.e. a wait is in progress.
    public private(set) var didStart = false

    public init() {}

    public mutating func start(_ conditions: Conditions) -> Action {
        didStart = true
        guard conditions.vmRunning else { return .exitImmediately }
        if conditions.guestShellAvailable { return .guestCommand }
        if conditions.canRequestStop { return .requestStop }
        return .forceStop
    }

    /// The graceful attempt did not work (guest has no power-off command, or
    /// `requestStop` was refused): go straight to the force stop.
    public mutating func gracefulAttemptFailed() -> Action { .forceStop }

    /// A second interrupt, or the expiry of `gracefulTimeout`, skips the rest
    /// of the wait.
    public mutating func abortWait() -> Action { .forceStop }
}

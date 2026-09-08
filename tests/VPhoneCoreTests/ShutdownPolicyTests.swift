import Testing
@testable import VPhoneCore

struct ShutdownPolicyTests {
    @Test func stopTimeoutOutlivesGracefulWait() {
        // `vm stop --timeout` must not SIGKILL the boot process while it is
        // still inside its own graceful wait or the force stop that follows it.
        #expect(Double(VPhoneShutdownPolicy.defaultStopTimeout) > VPhoneShutdownPolicy.gracefulTimeout)
        #expect(Double(VPhoneShutdownPolicy.defaultStopTimeout)
            >= VPhoneShutdownPolicy.gracefulTimeout + VPhoneShutdownPolicy.stopMargin)
        #expect(VPhoneShutdownPolicy.gracefulTimeout > 0)
    }

    @Test func guestCommandWinsWhenShellIsAvailable() {
        var plan = VPhoneShutdownPlan()
        #expect(!plan.didStart)
        #expect(plan.start(.init(vmRunning: true, guestShellAvailable: true, canRequestStop: true))
            == .guestCommand)
        #expect(plan.didStart)
    }

    @Test func requestStopIsTheFallbackAndForceStopIsTheLastResort() {
        var withRequestStop = VPhoneShutdownPlan()
        #expect(withRequestStop.start(
            .init(vmRunning: true, guestShellAvailable: false, canRequestStop: true)) == .requestStop)

        var withNeither = VPhoneShutdownPlan()
        #expect(withNeither.start(
            .init(vmRunning: true, guestShellAvailable: false, canRequestStop: false)) == .forceStop)
    }

    @Test func stoppedVMNeedsNoShutdown() {
        var plan = VPhoneShutdownPlan()
        #expect(plan.start(.init(vmRunning: false, guestShellAvailable: true, canRequestStop: true))
            == .exitImmediately)
    }

    @Test func repeatedInterruptAndTimeoutBothForceStop() {
        var plan = VPhoneShutdownPlan()
        _ = plan.start(.init(vmRunning: true, guestShellAvailable: true, canRequestStop: true))
        #expect(plan.abortWait() == .forceStop)
        #expect(plan.gracefulAttemptFailed() == .forceStop)
        #expect(plan.didStart)
    }

    @Test func guestHaltCommandIsPOSIXShellAndReportsMissingBinary() {
        let cmd = VPhoneShutdownPolicy.guestHaltCommand
        // Not executed here: on a macOS host `/sbin/halt` exists and would
        // power off the host. Structural checks only.
        #expect(cmd.contains("/var/jb/sbin/halt"))
        #expect(cmd.contains("exit \(VPhoneShutdownPolicy.guestHaltUnsupportedExitCode)"))
        #expect(!cmd.contains("[["))
        #expect(!cmd.contains("\n"))
    }
}

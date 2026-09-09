import Darwin
import Foundation
import Testing
@testable import VPhoneCore

// MARK: - Fixture

/// One throwaway VM bundle plus the child processes a test started.
///
/// The fake boot process must be seen by the real `ps` + `VPhoneBootProcessLocator`
/// pair, i.e. its argv[0] must end in `vphone-cli` and it must carry
/// `--config <bundle>/config.plist`. A *copy* of `/bin/sh` is killed by AMFI on
/// this host (verified: exit 137), so the fixture puts a symlink named
/// `vphone-cli` next to the bundle instead: execve follows it to the real
/// `/bin/sh`, while argv[0] stays the symlink path.
private final class StopFixture {
    let root: URL
    let bundle: URL
    let shim: URL
    private var children: [Process] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmstop-\(UUID().uuidString)")
        bundle = root.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        shim = root.appendingPathComponent("vphone-cli")
        try FileManager.default.createSymbolicLink(
            at: shim, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        try Data("disk".utf8).write(to: diskURL)
    }

    var configURL: URL { bundle.appendingPathComponent("config.plist") }
    var diskURL: URL { bundle.appendingPathComponent("Disk.img") }

    /// Starts a process the locator accepts as this bundle's boot process.
    @discardableResult
    func spawnBoot(_ body: String) throws -> Process {
        try spawn(executable: shim, arguments: ["-c", ready(body), "--config", configURL.path])
    }

    /// Starts a process that is not a boot process of this bundle.
    @discardableResult
    func spawnPlain(_ body: String, _ extra: [String] = []) throws -> Process {
        try spawn(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", ready(body), "helper"] + extra)
    }

    /// Waits for the child's `ready` line so a test never races its trap setup.
    private func spawn(executable: URL, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        children.append(process)
        #expect(!pipe.fileHandleForReading.availableData.isEmpty)
        return process
    }

    private func ready(_ body: String) -> String { "\(body); echo ready; while true; do sleep 0.2; done" }

    func terminateAll() {
        for child in children where child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
        for child in children { child.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }

    /// A zombie no longer runs and no longer holds files or locks, so it counts
    /// as gone here too.
    static func isRunning(_ pid: pid_t) -> Bool {
        guard let identity = VPhoneProcessInfo.identity(of: pid) else { return false }
        return !identity.isZombie
    }
}

/// Records every signal a stopper sends and forwards it to the kernel.
private final class SignalLog: @unchecked Sendable {
    private(set) var sent: [(pid: pid_t, signal: Int32)] = []

    func deliver(_ pid: pid_t, _ signal: Int32) -> Int32 {
        sent.append((pid, signal))
        return kill(pid, signal) == 0 ? 0 : errno
    }

    func record(_ pid: pid_t, _ signal: Int32) -> Int32 {
        sent.append((pid, signal))
        return 0
    }

    func count(_ pid: pid_t) -> Int { sent.filter { $0.pid == pid }.count }
    func signals(_ pid: pid_t) -> [Int32] { sent.filter { $0.pid == pid }.map(\.signal) }
}

/// Answers a fixed sequence, repeating the last element.
private final class Answers<Value>: @unchecked Sendable {
    private let values: [Value]
    private var index = 0
    init(_ values: [Value]) { self.values = values }
    func next() -> Value {
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

// MARK: - Tests

struct VMStopTests {
    private func stopper(
        fixture: StopFixture, log: SignalLog, lockHeld: @escaping () -> Bool
    ) -> VPhoneVMStopper {
        VPhoneVMStopper(
            listTargets: {
                guard let ps = try? VPhoneProcessRunner.runCapturing(
                    URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="]) else { return [] }
                return VPhoneBootProcessLocator.parsePIDs(ps.stdout, configURL: fixture.configURL)
            },
            send: { log.deliver($0, $1) },
            lockHeld: lockHeld,
            readRecord: { VPhoneVMRuntimeState.read(in: fixture.bundle) },
            diskHolders: {
                guard let lsof = try? VPhoneProcessRunner.runCapturing(
                    URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "--", fixture.diskURL.path])
                else { return [] }
                return VPhoneLsof.parsePIDs(lsof.stdout)
            })
    }

    // MARK: Process identity

    @Test func identityDescribesLiveProcessAndDropsReapedOne() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier

        let identity = try #require(VPhoneProcessInfo.identity(of: pid))
        #expect(identity.pid == pid)
        #expect(identity.uid == getuid())
        #expect(!identity.isZombie)
        let now = Date().timeIntervalSince1970
        #expect(identity.startedAt <= now)
        #expect(identity.startedAt >= now - 60)

        kill(pid, SIGKILL)
        child.waitUntilExit()
        #expect(VPhoneProcessInfo.identity(of: pid) == nil)
        #expect(VPhoneProcessInfo.identity(of: 0) == nil)
    }

    // MARK: Target selection

    @Test func locatorFindsTheFakeBootProcess() throws {
        let fixture = try StopFixture()
        defer { fixture.terminateAll() }
        let boot = try fixture.spawnBoot("true")

        let ps = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="])
        let found = VPhoneBootProcessLocator.parsePIDs(ps.stdout, configURL: fixture.configURL)
        #expect(found == [boot.processIdentifier])
    }

    @Test func neverSignalsAnotherProgramHoldingTheDiskImage() throws {
        let fixture = try StopFixture()
        defer { fixture.terminateAll() }
        let holder = try fixture.spawnPlain("exec 3< \"$1\"; trap '' INT", [fixture.diskURL.path])
        // `sh` only aborts a script on SIGINT when its foreground child was
        // killed by SIGINT too, so the stand-in installs an explicit handler —
        // which is also what the real boot process does.
        let boot = try fixture.spawnBoot("trap 'exit 0' INT")
        let log = SignalLog()
        let stop = stopper(fixture: fixture, log: log) {
            StopFixture.isRunning(boot.processIdentifier)
        }

        let outcome = stop.stop(timeout: 5, force: false)

        #expect(outcome == .stopped(signalled: [boot.processIdentifier], forceKilled: []))
        #expect(log.count(holder.processIdentifier) == 0)
        #expect(StopFixture.isRunning(holder.processIdentifier))
        #expect(log.signals(boot.processIdentifier) == [SIGINT])
    }

    // MARK: Signal escalation

    @Test func forceKillsAProcessThatIgnoresSIGINT() throws {
        let fixture = try StopFixture()
        defer { fixture.terminateAll() }
        let boot = try fixture.spawnBoot("trap '' INT")
        let log = SignalLog()
        // The lock is not taken by the fake process, so liveness is injected:
        // it mirrors what a real boot process's flock would report.
        let stop = stopper(fixture: fixture, log: log) {
            StopFixture.isRunning(boot.processIdentifier)
        }

        let outcome = stop.stop(timeout: 2, force: false)

        #expect(outcome == .stopped(signalled: [boot.processIdentifier],
                                    forceKilled: [boot.processIdentifier]))
        #expect(log.signals(boot.processIdentifier) == [SIGINT, SIGKILL])
        #expect(!StopFixture.isRunning(boot.processIdentifier))
    }

    @Test func forceSkipsSIGINTButStillConfirms() throws {
        let fixture = try StopFixture()
        defer { fixture.terminateAll() }
        let boot = try fixture.spawnBoot("trap '' INT")
        let log = SignalLog()
        let stop = stopper(fixture: fixture, log: log) {
            StopFixture.isRunning(boot.processIdentifier)
        }

        let outcome = stop.stop(timeout: 30, force: true)

        #expect(outcome == .stopped(signalled: [], forceKilled: [boot.processIdentifier]))
        #expect(log.signals(boot.processIdentifier) == [SIGKILL])
    }

    // MARK: Already exited

    @Test func reportsNotRunningWhenNothingHoldsTheLock() throws {
        let fixture = try StopFixture()
        defer { fixture.terminateAll() }
        let boot = try fixture.spawnBoot("true")
        kill(boot.processIdentifier, SIGKILL)
        boot.waitUntilExit()
        let log = SignalLog()
        let stop = stopper(fixture: fixture, log: log) {
            VPhoneVMLockProbe.isLockHeld(directory: fixture.bundle)
        }

        #expect(stop.stop(timeout: 5, force: false) == .notRunning)
        #expect(log.sent.isEmpty)
    }

    @Test func refusesToSignalAForeignLockHolder() throws {
        let fixture = try StopFixture()
        defer { fixture.terminateAll() }
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        holder.arguments = [
            "python3", "-c",
            "import os,fcntl,sys,time; f=os.open(sys.argv[1],os.O_RDONLY); "
                + "fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); time.sleep(30)",
            fixture.bundle.path,
        ]
        let pipe = Pipe()
        holder.standardOutput = pipe
        try holder.run()
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) }; holder.waitUntilExit() }
        #expect(!pipe.fileHandleForReading.availableData.isEmpty)

        try VPhoneVMRuntimeState(
            bundleIdentifier: "test", bundlePath: fixture.bundle.path,
            pid: holder.processIdentifier, instanceID: "INSTANCE-1", startedAt: Date(),
            operation: VPhoneVMRuntimeState.bootOperation).write(in: fixture.bundle)

        let log = SignalLog()
        let stop = stopper(fixture: fixture, log: log) {
            VPhoneVMLockProbe.isLockHeld(directory: fixture.bundle)
        }
        let outcome = stop.stop(timeout: 5, force: false)

        guard case let .noBootTarget(detail) = outcome else {
            Issue.record("expected .noBootTarget, got \(outcome)")
            return
        }
        #expect(detail.contains("pid \(holder.processIdentifier)"))
        #expect(detail.contains("INSTANCE-1"))
        #expect(log.sent.isEmpty)
        #expect(StopFixture.isRunning(holder.processIdentifier))
        #expect(outcome.exitCode == 1)
    }

    // MARK: Stale or reused pid

    @Test func treatsAReusedPIDAsExitedAndNeverKillsIt() {
        let pid: pid_t = 424_242
        let log = SignalLog()
        // Same pid, different start time on the second read: the number was
        // handed to another process while the stopper was waiting.
        let identities = Answers<VPhoneProcessIdentity?>([
            VPhoneProcessIdentity(pid: pid, startedAt: 1_000, uid: 501),
            VPhoneProcessIdentity(pid: pid, startedAt: 1_100, uid: 0),
        ])
        let locks = Answers<Bool>([true, false])
        let stop = VPhoneVMStopper(
            listTargets: { [pid] },
            identity: { _ in identities.next() },
            send: { log.record($0, $1) },
            lockHeld: { locks.next() },
            sleep: { _ in })

        let outcome = stop.stop(timeout: 5, force: false)

        #expect(outcome == .stopped(signalled: [pid], forceKilled: []))
        #expect(log.signals(pid) == [SIGINT])
    }

    @Test func doesNotKillAPIDThatLeftTheProcessListDuringTheWait() {
        let pid: pid_t = 424_243
        let log = SignalLog()
        let identity = VPhoneProcessIdentity(pid: pid, startedAt: 2_000, uid: 501)
        let listings = Answers<[pid_t]>([[pid], []])
        let locks = Answers<Bool>([true, true, false])
        let stop = VPhoneVMStopper(
            listTargets: { listings.next() },
            identity: { _ in identity },
            send: { log.record($0, $1) },
            lockHeld: { locks.next() },
            sleep: { _ in })

        let outcome = stop.stop(timeout: 2, force: false)

        // The kernel still reports the pid, but ps no longer lists it as this
        // bundle's boot process, so the escalation drops it.
        #expect(log.signals(pid) == [SIGINT])
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
    }

    // MARK: Failure reporting

    @Test func reportsFailureWhenTheTargetSurvives() {
        let pid: pid_t = 424_244
        let log = SignalLog()
        let identity = VPhoneProcessIdentity(pid: pid, startedAt: 3_000, uid: 501)
        let stop = VPhoneVMStopper(
            listTargets: { [pid] },
            identity: { _ in identity },
            send: { log.record($0, $1) },
            lockHeld: { true },
            sleep: { _ in })

        let outcome = stop.stop(timeout: 2, force: true)

        guard case let .failed(survivors, reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(survivors == [pid])
        #expect(reason.contains("still running"))
        #expect(reason.contains("bundle lock"))
        #expect(outcome.exitCode == 1)
    }

    @Test func reportsSignalErrorsSeparately() {
        let pid: pid_t = 424_245
        let identity = VPhoneProcessIdentity(pid: pid, startedAt: 4_000, uid: 0)
        let stop = VPhoneVMStopper(
            listTargets: { [pid] },
            identity: { _ in identity },
            send: { _, _ in EPERM },
            lockHeld: { true },
            sleep: { _ in })

        guard case let .failed(_, reason) = stop.stop(timeout: 1, force: true) else {
            Issue.record("expected .failed")
            return
        }
        #expect(reason.contains(String(cString: strerror(EPERM))))
        #expect(!reason.contains(String(cString: strerror(ESRCH))))
    }

    @Test func mapsOutcomesToExitCodes() {
        #expect(VPhoneVMStopper.Outcome.notRunning.exitCode == 0)
        #expect(VPhoneVMStopper.Outcome.stopped(signalled: [1], forceKilled: []).exitCode == 0)
        #expect(VPhoneVMStopper.Outcome.noBootTarget(detail: "x").exitCode == 1)
        #expect(VPhoneVMStopper.Outcome.failed(survivors: [1], reason: "x").exitCode == 1)
    }

    // MARK: Progress events

    @Test func reportsProgressBeforeTheWaits() throws {
        let fixture = try StopFixture()
        defer { fixture.terminateAll() }
        let boot = try fixture.spawnBoot("trap '' INT")
        try VPhoneVMRuntimeState(
            bundleIdentifier: "test", bundlePath: fixture.bundle.path,
            pid: boot.processIdentifier, instanceID: "INSTANCE-2", startedAt: Date(),
            operation: VPhoneVMRuntimeState.bootOperation).write(in: fixture.bundle)

        let events = EventLog()
        var stop = stopper(fixture: fixture, log: SignalLog()) {
            StopFixture.isRunning(boot.processIdentifier)
        }
        stop.report = { events.append($0) }

        _ = stop.stop(timeout: 2, force: false)

        #expect(events.values == [
            .bootInstance("INSTANCE-2"),
            .signalling([boot.processIdentifier]),
            .forceKilling([boot.processIdentifier]),
        ])
    }
}

private final class EventLog: @unchecked Sendable {
    private(set) var values: [VPhoneVMStopper.Event] = []
    func append(_ event: VPhoneVMStopper.Event) { values.append(event) }
}

import Darwin
import Foundation

// MARK: - VPhoneChildCancellation

/// Cancellation of a long operation that runs stage children (`vm create`).
///
/// Foundation `Process` starts every child in a new process group (verified:
/// `ChildCancellationTests.foundationProcessStartsANewProcessGroup`), so a
/// signal sent to the operation's own process group — Launchpad's Stop
/// Creating is `killpg(<vm create pid>, SIGINT)` — reaches the operation but
/// none of its children. Spawn helpers (`VPhoneProcessRunner`,
/// `VPhoneManagedProcess`) register every child with the controller bound to
/// `current`; on SIGINT/SIGTERM the controller
///
/// 1. sends the same signal to each running child, to the process group of
///    each of its descendants, and to each descendant (a descendant may have
///    left the child's group with setpgid/setsid);
/// 2. after the child's grace period sends SIGKILL to every process it
///    signalled that still runs, including descendants orphaned meanwhile;
/// 3. leaves the stage loop to stop at its next check (`requestedSignal`),
///    so the running stage stays `running` in the checkpoint (overall
///    `interrupted`) and the locks are released by the normal return;
/// 4. exits the process itself if that return does not happen within
///    `Timing.forcedExit`, after killing the stage processes and after any
///    checkpoint write in progress (`withExitDeferred`) has finished.
///
/// A child that runs as root cannot be signalled by this process. Inside
/// `deferring(_:)` (the CFW install) nothing is forwarded or killed and the
/// process does not exit early: it waits for that child to finish and stops
/// afterwards. Killing the user-owned parent of a root child would leave the
/// root child running and holding the bundle lock (D4 scenario 2).
public final class VPhoneChildCancellation: @unchecked Sendable {
    /// The controller spawn helpers register with. Bound by `vm create` for
    /// the whole command; nil elsewhere, where nothing is registered.
    @TaskLocal public static var current: VPhoneChildCancellation?

    public enum ChildKind: Sendable {
        /// A script or tool (fw prepare, restore bridge, CFW driver, probes).
        case tool
        /// A VM process (`--dfu`, first boot, verification boot). On SIGINT it
        /// asks the guest to power off and waits up to
        /// `VPhoneShutdownPolicy.gracefulTimeout` before force-stopping.
        case virtualMachine
    }

    public struct Timing: Sendable {
        public var toolGrace: TimeInterval
        public var virtualMachineGrace: TimeInterval
        /// Seconds after the first signal before the process exits by itself.
        public var forcedExit: TimeInterval
        /// Upper bound of `settle()` after the latest escalation deadline.
        public var settleMargin: TimeInterval

        public init(
            toolGrace: TimeInterval = 10,
            virtualMachineGrace: TimeInterval = TimeInterval(VPhoneShutdownPolicy.defaultStopTimeout),
            forcedExit: TimeInterval = 90, settleMargin: TimeInterval = 10
        ) {
            self.toolGrace = toolGrace
            self.virtualMachineGrace = virtualMachineGrace
            self.forcedExit = forcedExit
            self.settleMargin = settleMargin
        }

        func grace(_ kind: ChildKind) -> TimeInterval {
            kind == .virtualMachine ? virtualMachineGrace : toolGrace
        }
    }

    public struct Token: Hashable, Sendable {
        let value: Int
    }

    private struct Child {
        let pid: pid_t
        let label: String
        let kind: ChildKind
        let isRunning: () -> Bool
        var signalled = false
    }

    private let lock = NSLock()
    private var children: [Int: Child] = [:]
    private var nextToken = 0
    private var signal: Int32?
    private var escalateAt: Date?
    private var escalated = false
    private var deferral: String?
    private var completed = false
    /// Every process this controller signalled, by identity (pid reuse safe).
    private var signalled: [pid_t: VPhoneProcessIdentity] = [:]
    private var sources: [DispatchSourceSignal] = []
    private var previousHandlers: [Int32: sig_t?] = [:]
    private let queue = DispatchQueue(label: "vphone.child-cancellation")
    private let exitGate = NSLock()

    public let timing: Timing
    private let log: @Sendable (String) -> Void
    private let exitProcess: @Sendable (Int32) -> Void

    public init(
        timing: Timing = Timing(),
        log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
        exitProcess: @escaping @Sendable (Int32) -> Void = { code in fflush(nil); _exit(code) }
    ) {
        self.timing = timing
        self.log = log
        self.exitProcess = exitProcess
    }

    // MARK: State

    /// The first signal received, or nil while the operation is not cancelled.
    public var requestedSignal: Int32? { lock.withLock { signal } }
    public var isRequested: Bool { requestedSignal != nil }

    public func throwIfRequested() throws {
        if isRequested { throw CancellationError() }
    }

    /// Sleeps up to `interval`, returning early (throwing) once cancelled.
    public func sleep(_ interval: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            try throwIfRequested()
            Thread.sleep(forTimeInterval: min(0.1, max(0, deadline.timeIntervalSinceNow)))
        }
        try throwIfRequested()
    }

    public static func name(of signal: Int32) -> String {
        switch signal {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        case SIGKILL: "SIGKILL"
        default: "signal \(signal)"
        }
    }

    // MARK: Signals

    /// Routes SIGINT and SIGTERM of this process to `request(signal:)`.
    public func install(signals: [Int32] = [SIGINT, SIGTERM]) {
        lock.withLock {
            for number in signals where previousHandlers[number] == nil {
                previousHandlers[number] = Darwin.signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.request(signal: number) }
                source.resume()
                sources.append(source)
            }
        }
    }

    public func uninstall() {
        lock.withLock {
            sources.forEach { $0.cancel() }
            sources = []
            for (number, handler) in previousHandlers { Darwin.signal(number, handler ?? SIG_DFL) }
            previousHandlers = [:]
        }
    }

    // MARK: Registration

    /// Registers a started child. A child registered after the signal is
    /// signalled at once (unless a deferred stage runs).
    public func register(
        pid: pid_t, label: String, kind: ChildKind = .tool, isRunning: @escaping () -> Bool
    ) -> Token {
        let (token, pending, late): (Int, Int32?, Bool) = lock.withLock {
            let token = nextToken
            nextToken += 1
            children[token] = Child(pid: pid, label: label, kind: kind, isRunning: isRunning)
            return (token, deferral == nil ? signal : nil, escalated)
        }
        if let pending {
            deliver(late ? SIGKILL : pending, toChild: token)
            if !late { scheduleEscalation(after: timing.grace(kind)) }
        }
        return Token(value: token)
    }

    public func unregister(_ token: Token) {
        lock.withLock { _ = children.removeValue(forKey: token.value) }
    }

    /// Runs `body` while cancellation is deferred: no signal is forwarded, no
    /// process killed and no early exit taken until `body` returns.
    public func deferring<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        lock.withLock { deferral = label }
        defer {
            let pending: Int32? = lock.withLock {
                deferral = nil
                return signal
            }
            if pending != nil { log("[!] \(label) finished; stopping vm create") }
        }
        return try body()
    }

    /// Runs `body` with `current`'s deferral, or plainly without a controller.
    public static func deferring<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard let current else { return try body() }
        return try current.deferring(label, body)
    }

    /// Checkpoint writes run under this gate; the forced exit waits for it.
    public func withExitDeferred<T>(_ body: () throws -> T) rethrows -> T {
        exitGate.lock()
        defer { exitGate.unlock() }
        return try body()
    }

    // MARK: Request

    public func request(signal number: Int32) {
        let (first, deferredLabel, tokens): (Bool, String?, [Int]) = lock.withLock {
            let first = signal == nil
            if first { signal = number }
            return (first, deferral, Array(children.keys))
        }
        let name = Self.name(of: number)
        if let deferredLabel {
            log("[!] \(name) received while \(deferredLabel) runs. It runs as root and cannot be stopped from this "
                + "process; vm create waits for it to finish, then stops. "
                + "(Cancel the authentication dialog if it is still shown.)")
            if first { scheduleForcedExit() }
            return
        }
        if first {
            let labels = lock.withLock { tokens.compactMap { children[$0] }.filter { $0.isRunning() }.map(\.label) }
            log("[!] \(name) received; stopping " + (labels.isEmpty ? "vm create" : labels.joined(separator: ", "))
                + " and recording the running stage as interrupted")
            var grace: TimeInterval = 0
            for token in tokens {
                deliver(number, toChild: token)
                if let kind = lock.withLock({ children[token]?.kind }) { grace = max(grace, timing.grace(kind)) }
            }
            scheduleEscalation(after: grace)
            scheduleForcedExit()
        } else {
            log("[!] another \(name); killing the stage processes now")
            escalate()
        }
    }

    /// Waits until every signalled process and every registered child has
    /// exited, sending SIGKILL once the escalation deadline passes. Returns
    /// false when processes remain after `Timing.settleMargin`.
    @discardableResult
    public func settle() -> Bool {
        guard isRequested else { return true }
        let start = Date()
        while true {
            let remaining = liveProcesses()
            if remaining.isEmpty { return true }
            let deadline = lock.withLock { escalateAt } ?? start
            if Date() >= deadline { escalate() }
            if Date() >= deadline.addingTimeInterval(timing.settleMargin) {
                log("[!] processes still running after SIGKILL: " + remaining.map(String.init).joined(separator: ", "))
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// The operation returned; no forced exit follows.
    public func complete() {
        lock.withLock { completed = true }
    }

    // MARK: Delivery

    private func deliver(_ number: Int32, toChild token: Int) {
        let child: Child? = lock.withLock {
            guard var child = children[token], child.isRunning() else { return nil }
            child.signalled = true
            children[token] = child
            return child
        }
        guard let child else { return }
        send(number, toTree: child.pid)
    }

    /// Signals `root`, every descendant, and the process group of each.
    private func send(_ number: Int32, toTree root: pid_t) {
        let table = VPhoneProcessInfo.table()
        var tree: [pid_t] = [root]
        var index = 0
        while index < tree.count {
            let parent = tree[index]
            tree += table.filter { $0.ppid == parent && $0.pid != parent }.map(\.pid)
            index += 1
        }
        let own = getpgrp()
        let groups = Set(tree.map { pid in table.first { $0.pid == pid }?.pgid ?? getpgid(pid) })
            .filter { $0 > 1 && $0 != own }
        lock.withLock {
            for pid in tree where signalled[pid] == nil {
                if let identity = VPhoneProcessInfo.identity(of: pid) { signalled[pid] = identity }
            }
        }
        for group in groups { killpg(group, number) }
        for pid in tree where pid > 1 && pid != getpid() { kill(pid, number) }
    }

    private func scheduleEscalation(after grace: TimeInterval) {
        let at = Date().addingTimeInterval(grace)
        lock.withLock { escalateAt = max(escalateAt ?? at, at) }
        queue.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self else { return }
            let due = lock.withLock { !completed && deferral == nil && (escalateAt ?? .distantFuture) <= Date() }
            if due, !liveProcesses().isEmpty { escalate() }
        }
    }

    /// SIGKILL to every registered child tree and every signalled process
    /// that still runs (orphans included), and to their process groups.
    private func escalate() {
        let (tokens, known): ([Int], [VPhoneProcessIdentity]) = lock.withLock {
            escalated = true
            return (Array(children.keys), Array(signalled.values))
        }
        let survivors = known.filter(Self.isAlive)
        let registeredRunning = lock.withLock { tokens.contains { children[$0]?.isRunning() == true } }
        if !survivors.isEmpty || registeredRunning {
            log("[!] stage processes did not exit after the signal; sending SIGKILL")
        }
        for token in tokens { deliver(SIGKILL, toChild: token) }
        let own = getpgrp()
        for identity in survivors where Self.isAlive(identity) {
            let group = getpgid(identity.pid)
            if group > 1, group != own { killpg(group, SIGKILL) }
            send(SIGKILL, toTree: identity.pid)
        }
    }

    private func liveProcesses() -> [pid_t] {
        let (running, known): ([pid_t], [VPhoneProcessIdentity]) = lock.withLock {
            (children.values.filter { $0.isRunning() }.map(\.pid), Array(signalled.values))
        }
        return Array(Set(running + known.filter(Self.isAlive).map(\.pid))).sorted()
    }

    private static func isAlive(_ identity: VPhoneProcessIdentity) -> Bool {
        guard let now = VPhoneProcessInfo.identity(of: identity.pid) else { return false }
        return now.startedAt == identity.startedAt && !now.isZombie
    }

    // MARK: Forced exit

    private func scheduleForcedExit() {
        queue.asyncAfter(deadline: .now() + timing.forcedExit) { [weak self] in self?.forcedExitIfStillRunning() }
    }

    private func forcedExitIfStillRunning() {
        let (done, deferredLabel, number) = lock.withLock { (completed, deferral, signal) }
        guard !done, let number else { return }
        if deferredLabel != nil {
            // The root child decides when the process may stop; check again later.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.forcedExitIfStillRunning() }
            return
        }
        log("[!] vm create did not stop within \(Int(timing.forcedExit))s of \(Self.name(of: number)); "
            + "ending the stage processes and exiting")
        escalate()
        settleQuietly(bound: 5)
        // A checkpoint write in progress finishes first, so the file on disk
        // is the previous or the new version and the stage stays `running`.
        _ = exitGate.lock(before: Date().addingTimeInterval(35))
        exitProcess(128 + number)
    }

    private func settleQuietly(bound: TimeInterval) {
        let deadline = Date().addingTimeInterval(bound)
        while !liveProcesses().isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }
}

// MARK: - Process table

extension VPhoneProcessInfo {
    public struct Entry: Equatable, Sendable {
        public let pid: pid_t
        public let ppid: pid_t
        public let pgid: pid_t
    }

    /// pid, parent pid and process group of every process (`KERN_PROC_ALL`).
    public static func table() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            // The table may grow between the two calls.
            size += size / 4
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            var used = buffer.count * MemoryLayout<kinfo_proc>.stride
            let result = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &used, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue }
                return []
            }
            return buffer.prefix(used / MemoryLayout<kinfo_proc>.stride).map {
                Entry(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid, pgid: $0.kp_eproc.e_pgid)
            }
        }
        return []
    }
}

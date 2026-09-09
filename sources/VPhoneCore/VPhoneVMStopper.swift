import Darwin
import Foundation

// MARK: - VPhoneVMStopper

/// Decides which processes `vm stop` may signal and drives the
/// SIGINT → wait → SIGKILL → confirm sequence.
///
/// Separated from the CLI so the whole decision path can be tested with real
/// subprocesses or injected closures. The CLI keeps only argument parsing,
/// output and exit codes.
///
/// Two rules make the sequence safe:
///
/// 1. A target is a `(pid, startedAt)` pair, never a bare pid. The wait between
///    SIGINT and SIGKILL can last tens of seconds, long enough for the pid to be
///    reused; a different `startedAt` means the original process exited and the
///    number now belongs to somebody else, who must not be signalled.
/// 2. Success is confirmed, not assumed. After a SIGKILL the stopper waits for
///    the targets to disappear and for the bundle lock to be released before it
///    reports `.stopped`.
public struct VPhoneVMStopper {
    // MARK: Outcome

    public enum Outcome: Equatable, Sendable {
        /// Nothing holds the bundle lock.
        case notRunning
        /// The bundle lock is held, but not by a boot process of this bundle.
        /// Nothing was signalled.
        case noBootTarget(detail: String)
        /// Every target is gone and the bundle lock is released.
        case stopped(signalled: [pid_t], forceKilled: [pid_t])
        /// Targets outlived the sequence, or the lock was not released.
        case failed(survivors: [pid_t], reason: String)

        /// Process exit status the CLI reports for this outcome. Only a
        /// confirmed stop (or a VM that was not running) is a success.
        public var exitCode: Int32 {
            switch self {
            case .notRunning, .stopped: return 0
            case .noBootTarget, .failed: return 1
            }
        }
    }

    // MARK: Progress

    /// Progress of the sequence, emitted as it happens so a caller can print it
    /// before the waits rather than after them. The caller owns the wording.
    public enum Event: Equatable, Sendable {
        /// The runtime record corroborated a target; this is its boot instance.
        case bootInstance(String)
        case signalling([pid_t])
        case forceKilling([pid_t])
    }

    // MARK: Timing

    /// Poll granularity of the graceful wait.
    public static let pollInterval: TimeInterval = 1
    /// Bounded wait for the post-SIGKILL state check.
    ///
    /// It covers the gap between a target's death and the release of its lock:
    /// the boot process holds the flock itself, the kernel drops it when the
    /// process exits, and `vm launch` (which waits on the boot process) holds no
    /// lock while the VM runs — its `stage-vphoned` lock is released before the
    /// boot child is spawned. So the only delay expected here is process exit
    /// and reaping.
    public static let confirmWindow: TimeInterval = 3
    public static let confirmPollInterval: TimeInterval = 0.5

    // MARK: Dependencies

    /// PIDs that currently look like boot processes of this bundle.
    public var listTargets: () -> [pid_t]
    /// Kernel identity of a pid, nil when it does not exist.
    public var identity: (pid_t) -> VPhoneProcessIdentity?
    /// Sends a signal; returns 0 on success or the errno value.
    public var send: (pid_t, Int32) -> Int32
    /// True while some process holds the bundle directory flock.
    public var lockHeld: () -> Bool
    public var sleep: (TimeInterval) -> Void
    /// Diagnostic record of the current lock holder, if readable.
    public var readRecord: () -> VPhoneVMRuntimeState?
    /// PIDs holding the disk image open. Diagnosis only — never signalled.
    public var diskHolders: () -> [pid_t]
    /// Progress sink; see `Event`.
    public var report: (Event) -> Void

    public init(
        listTargets: @escaping () -> [pid_t],
        identity: @escaping (pid_t) -> VPhoneProcessIdentity? = { VPhoneProcessInfo.identity(of: $0) },
        send: @escaping (pid_t, Int32) -> Int32 = { pid, signal in kill(pid, signal) == 0 ? 0 : errno },
        lockHeld: @escaping () -> Bool,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        readRecord: @escaping () -> VPhoneVMRuntimeState? = { nil },
        diskHolders: @escaping () -> [pid_t] = { [] },
        report: @escaping (Event) -> Void = { _ in }
    ) {
        self.listTargets = listTargets
        self.identity = identity
        self.send = send
        self.lockHeld = lockHeld
        self.sleep = sleep
        self.readRecord = readRecord
        self.diskHolders = diskHolders
        self.report = report
    }

    /// Production wiring for one bundle.
    ///
    /// Targets come from `ps` + `VPhoneBootProcessLocator`, deliberately not
    /// from `lsof Disk.img`: the disk image is opened by the
    /// Virtualization.framework helper process, so a file holder lookup names
    /// the helper and never the process that owns the VM lifecycle. `lsof` is
    /// wired in as `diskHolders` for diagnosis only.
    public init(
        bundleDirectory: URL, configURL: URL, diskURL: URL,
        report: @escaping (Event) -> Void = { _ in }
    ) {
        self.init(
            listTargets: {
                guard let ps = try? VPhoneProcessRunner.runCapturing(
                    URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="]) else { return [] }
                return VPhoneBootProcessLocator.parsePIDs(ps.stdout, configURL: configURL)
            },
            lockHeld: { VPhoneVMLockProbe.isLockHeld(directory: bundleDirectory) },
            readRecord: { VPhoneVMRuntimeState.read(in: bundleDirectory) },
            diskHolders: {
                guard FileManager.default.fileExists(atPath: diskURL.path),
                      let lsof = try? VPhoneProcessRunner.runCapturing(
                          URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "--", diskURL.path])
                else { return [] }
                return VPhoneLsof.parsePIDs(lsof.stdout)
            },
            report: report)
    }

    // MARK: Sequence

    /// Runs the whole stop sequence. `timeout` is the graceful wait in seconds;
    /// `force` skips SIGINT and the wait, but not the final confirmation.
    public func stop(timeout: TimeInterval, force: Bool) -> Outcome {
        guard lockHeld() else { return .notRunning }

        // A target is only ever a process ps still lists AND the kernel still
        // knows; a pid that vanished between the two reads is dropped here.
        let snapshot = liveIdentities(listTargets())
        guard !snapshot.isEmpty else { return .noBootTarget(detail: noTargetDetail()) }
        if let instanceID = confirmedInstanceID(among: snapshot) {
            report(.bootInstance(instanceID))
        }

        var sendErrors: [pid_t: Int32] = [:]
        var signalled: [pid_t] = []

        if !force {
            report(.signalling(snapshot.map(\.pid).sorted()))
            for target in snapshot {
                let code = send(target.pid, SIGINT)
                if code == 0 { signalled.append(target.pid) } else { sendErrors[target.pid] = code }
            }
            var waited: TimeInterval = 0
            while waited < timeout, !survivors(of: snapshot).isEmpty {
                sleep(Self.pollInterval)
                waited += Self.pollInterval
            }
        }

        // Re-confirm identity before escalating. In the graceful path the
        // snapshot may be up to `timeout` seconds old, so both the kernel record
        // and the process list are read again and only the intersection is
        // killed.
        var remaining = survivors(of: snapshot)
        if !force {
            let current = Set(liveIdentities(listTargets()))
            remaining = remaining.filter { current.contains($0) }
        }

        var forceKilled: [pid_t] = []
        if !remaining.isEmpty { report(.forceKilling(remaining.map(\.pid).sorted())) }
        for target in remaining {
            let code = send(target.pid, SIGKILL)
            if code == 0 { forceKilled.append(target.pid) } else { sendErrors[target.pid] = code }
        }

        // Confirm the actual state instead of assuming the signals worked.
        var waited: TimeInterval = 0
        while waited < Self.confirmWindow, !survivors(of: snapshot).isEmpty || lockHeld() {
            sleep(Self.confirmPollInterval)
            waited += Self.confirmPollInterval
        }

        let stillAlive = survivors(of: snapshot)
        let stillLocked = lockHeld()
        if stillAlive.isEmpty, !stillLocked {
            return .stopped(signalled: signalled.sorted(), forceKilled: forceKilled.sorted())
        }
        return .failed(
            survivors: stillAlive.map(\.pid).sorted(),
            reason: failureReason(
                survivors: stillAlive, sendErrors: sendErrors, lockHeld: stillLocked))
    }

    /// instanceID of the runtime record when it names a process that is actually
    /// one of the current targets. A record alone proves nothing: it is never
    /// deleted on exit, so it survives every VM run and can name a reused pid.
    private func confirmedInstanceID(among snapshot: [VPhoneProcessIdentity]) -> String? {
        guard let record = readRecord(), record.isBootOperation else { return nil }
        guard snapshot.contains(where: { $0.pid == record.pid }) else { return nil }
        return record.instanceID
    }

    // MARK: Helpers

    private func liveIdentities(_ pids: [pid_t]) -> [VPhoneProcessIdentity] {
        pids.compactMap(identity).filter { !$0.isZombie }
    }

    /// A snapshot entry is still the same process only when the kernel reports
    /// the same start time. A missing record, a different start time or a
    /// zombie all mean "exited"; such an entry is never signalled again.
    private func survivors(of snapshot: [VPhoneProcessIdentity]) -> [VPhoneProcessIdentity] {
        snapshot.filter { target in
            guard let now = identity(target.pid), !now.isZombie else { return false }
            return now.startedAt == target.startedAt
        }
    }

    private func noTargetDetail() -> String {
        var detail = "no vphone-cli boot process is running for it"
        if let record = readRecord(), let holder = identity(record.pid), !holder.isZombie {
            detail = "it is held by pid \(record.pid) running operation \"\(record.operation)\""
            if record.isBootOperation { detail += " (instance \(record.instanceID))" }
        }
        let holders = diskHolders()
        if !holders.isEmpty {
            detail += "; Disk.img is open in \(holders.map(String.init).joined(separator: ", "))"
                + " (diagnosis only, not signalled)"
        }
        return detail
    }

    private func failureReason(
        survivors: [VPhoneProcessIdentity], sendErrors: [pid_t: Int32], lockHeld: Bool
    ) -> String {
        var parts: [String] = []
        if !survivors.isEmpty {
            parts.append("\(survivors.map { String($0.pid) }.joined(separator: ", ")) still running")
        } else {
            parts.append("all targets exited")
        }
        if !sendErrors.isEmpty {
            let listed = sendErrors.keys.sorted().map { pid -> String in
                let code = sendErrors[pid]!
                return "\(pid): \(String(cString: strerror(code)))"
            }
            parts.append("signal errors — " + listed.joined(separator: ", "))
        }
        if lockHeld {
            parts.append("the bundle lock was still held after \(Int(Self.confirmWindow))s")
        }
        return parts.joined(separator: "; ")
    }
}

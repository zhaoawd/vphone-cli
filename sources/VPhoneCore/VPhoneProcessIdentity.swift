import Darwin

// MARK: - VPhoneProcessIdentity

/// Identity of a live process, stable across pid reuse.
///
/// A pid alone cannot identify a process across a wait: the kernel may hand the
/// same number to a new process after the original exits. `startedAt` (the
/// kernel's `p_starttime`) plus the pid distinguishes the process that was
/// observed from any later occupant of the same number.
public struct VPhoneProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    /// Process start time in seconds since the epoch, from
    /// `kinfo_proc.kp_proc.p_starttime`.
    public let startedAt: Double
    public let uid: uid_t
    /// True when the process has exited but has not been reaped yet
    /// (`p_stat == SZOMB`). Such a pid still has a kernel record, but the
    /// process no longer runs and no longer holds files or locks.
    public let isZombie: Bool

    public init(pid: pid_t, startedAt: Double, uid: uid_t, isZombie: Bool = false) {
        self.pid = pid
        self.startedAt = startedAt
        self.uid = uid
        self.isZombie = isZombie
    }
}

// MARK: - VPhoneProcessInfo

public enum VPhoneProcessInfo {
    /// Reads the kernel's process record for `pid`.
    ///
    /// Returns nil when no such process exists. `sysctl` reports that in two
    /// ways on macOS: success with a zero-length result (verified locally), or
    /// failure with `ENOENT`/`ESRCH`. Both are treated as "gone".
    public static func identity(of pid: pid_t) -> VPhoneProcessIdentity? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        guard size >= MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return VPhoneProcessIdentity(
            pid: pid,
            startedAt: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000,
            uid: info.kp_eproc.e_ucred.cr_uid,
            isZombie: info.kp_proc.p_stat == Int8(SZOMB))
    }
}

import Darwin
import Foundation

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

    /// Returns argv only. Never logs the sysctl buffer, which can also contain
    /// environment values. Unreadable or malformed process data is refused.
    public static func arguments(of pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        var limit: Int32 = 0
        var limitSize = MemoryLayout<Int32>.size
        var limitMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitMIB, 2, &limit, &limitSize, nil, 0) == 0,
              limit > 0, limit <= 16 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(limit))
        var size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, 3, buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size <= bytes.count, size > MemoryLayout<Int32>.size else { return nil }
        bytes.removeSubrange(size...)
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= size else { return nil }
        var offset = MemoryLayout<Int32>.size
        // KERN_PROCARGS2: argc, executable path, NUL padding, argv strings.
        while offset < size, bytes[offset] != 0 { offset += 1 }
        while offset < size, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            let start = offset
            while offset < size, bytes[offset] != 0 { offset += 1 }
            guard offset < size, let argument = String(bytes: bytes[start..<offset], encoding: .utf8) else { return nil }
            arguments.append(argument)
            offset += 1
        }
        return arguments
    }
}

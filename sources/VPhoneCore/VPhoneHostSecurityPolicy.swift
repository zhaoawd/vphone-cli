import Darwin
import Foundation

/// The running kernel's System Integrity Protection configuration, read with
/// `csr_get_active_config` from libSystem. Adapted from upstream 2.2.3
/// `VPhoneLaunchpadHostPolicy` (a23a765): unlike `csrutil`, the query needs
/// no terminal and no administrator rights and does not ask which macOS
/// installation to inspect on a Mac with several. Read-only; never changes policy.
public enum VPhoneHostSecurityPolicy {
    public typealias CSRQuery = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32

    // XNU bsd/sys/csr.h
    public static let allowTaskForPID: UInt32 = 1 << 2
    public static let allowResearchGuests: UInt32 = 1 << 12

    public enum Reading: Equatable, Sendable {
        case configuration(UInt32)
        /// The query could not answer; the text names why.
        case unavailable(String)
    }

    public static func activeConfiguration() -> Reading {
        guard let library = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_LOCAL) else {
            return .unavailable("libSystem could not be loaded")
        }
        defer { dlclose(library) }
        let query = dlsym(library, "csr_get_active_config").map { unsafeBitCast($0, to: CSRQuery.self) }
        return activeConfiguration(query: query)
    }

    /// Injectable so a missing symbol and a failed call are tested without
    /// touching the host configuration. A failed call never yields a value,
    /// even when it wrote one.
    public static func activeConfiguration(query: CSRQuery?) -> Reading {
        guard let query else { return .unavailable("csr_get_active_config is unavailable") }
        var configuration: UInt32 = 0
        errno = 0
        let status = query(&configuration)
        let queryErrno = errno
        guard status == 0 else {
            return .unavailable("csr_get_active_config failed (status \(status), errno \(queryErrno))")
        }
        return .configuration(configuration)
    }

    public static func hex(_ configuration: UInt32) -> String { String(format: "0x%08x", configuration) }
}

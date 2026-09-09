import Darwin
import Foundation

// MARK: - Errors

public enum VPhoneBundleGuardError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// An offline operation could not take the bundle's exclusive lock.
    case busy(bundle: String, detail: String)
    /// `restore` was asked to work on a bundle that is not in a verified DFU
    /// session (see `VPhoneBundleGuard.requireDFUOwner`).
    case dfuSessionRequired(bundle: String, detail: String)

    public var description: String {
        switch self {
        case let .busy(bundle, detail):
            return "VM '\(bundle)' is busy: \(detail)"
        case let .dfuSessionRequired(bundle, detail):
            return "VM '\(bundle)' is not in a DFU restore session: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - VPhoneBundleGuard

/// One place where every offline bundle operation takes its occupancy
/// protection, so no entry point can be protected differently from another.
///
/// Two rules, both consequences of the lock being advisory and the runtime
/// record being diagnostic only:
///
/// 1. Exclusive operations (`withBundleLock`) hold the kernel lock across the
///    whole check-then-write window. The record is read only to *explain* a
///    refusal; it never decides one.
/// 2. `restore` cannot take the lock — the DFU boot it drives holds it for the
///    whole session — so it verifies the holder instead (`requireDFUOwner`):
///    the record must name a DFU operation whose pid is a live, non-zombie
///    `vphone-cli --config <this bundle>` process. A boot holder, an offline
///    holder, an unreadable record or an unheld lock all refuse.
///
/// Process and filesystem access is injected so the whole decision path can be
/// tested with real child processes or with fakes, as in `VPhoneVMStopper`.
public struct VPhoneBundleGuard: Sendable {
    /// True while some process holds the bundle directory flock.
    public var lockHeld: @Sendable (URL) -> Bool
    /// Diagnostic record of the current holder, if readable.
    public var readRecord: @Sendable (URL) -> VPhoneVMRuntimeState?
    /// Kernel identity of a pid, nil when it does not exist.
    public var identity: @Sendable (pid_t) -> VPhoneProcessIdentity?
    /// PIDs that currently look like boot processes for a bundle's config path.
    public var bootPIDs: @Sendable (URL) -> [pid_t]

    public init(
        lockHeld: @escaping @Sendable (URL) -> Bool = { VPhoneVMLockProbe.isLockHeld(directory: $0) },
        readRecord: @escaping @Sendable (URL) -> VPhoneVMRuntimeState? = { VPhoneVMRuntimeState.read(in: $0) },
        identity: @escaping @Sendable (pid_t) -> VPhoneProcessIdentity? = { VPhoneProcessInfo.identity(of: $0) },
        bootPIDs: @escaping @Sendable (URL) -> [pid_t] = { configURL in
            guard let ps = try? VPhoneProcessRunner.runCapturing(
                URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="]) else { return [] }
            return VPhoneBootProcessLocator.parsePIDs(ps.stdout, configURL: configURL)
        }
    ) {
        self.lockHeld = lockHeld
        self.readRecord = readRecord
        self.identity = identity
        self.bootPIDs = bootPIDs
    }

    /// Production wiring.
    public static let live = VPhoneBundleGuard()

    // MARK: Exclusive operations

    /// Runs `body` while holding the bundle's exclusive lock, refusing with one
    /// uniform error when another process holds it.
    ///
    /// The lock is passed in so a callee can require proof that it runs under
    /// it (see `VPhoneRestoreInfo.recordVariant`). Do not take a second bundle
    /// lock inside `body`: `flock` is per open file description, so a nested
    /// acquisition on the same directory fails even in the same process.
    @discardableResult
    public func withBundleLock<T>(
        directory: URL, operation: String, _ body: (VPhoneVMLock) throws -> T
    ) throws -> T {
        let lock: VPhoneVMLock
        do {
            lock = try VPhoneVMLock(directory: directory, operation: operation)
        } catch {
            throw VPhoneBundleGuardError.busy(
                bundle: Self.bundleName(directory), detail: holderDetail(directory: directory))
        }
        defer { withExtendedLifetime(lock) {} }
        return try body(lock)
    }

    @discardableResult
    public static func withBundleLock<T>(
        directory: URL, operation: String, _ body: (VPhoneVMLock) throws -> T
    ) throws -> T {
        try live.withBundleLock(directory: directory, operation: operation, body)
    }

    /// Runs `body` while holding the library-root lock (the VM name space).
    /// Used by operations that place or remove a bundle *name*, where no bundle
    /// directory exists yet to lock.
    @discardableResult
    public func withLibraryLock<T>(
        root: URL, timeout: TimeInterval = VPhoneLibraryLock.defaultTimeout, _ body: (VPhoneLibraryLock) throws -> T
    ) throws -> T {
        let lock = try VPhoneLibraryLock(root: root, timeout: timeout)
        defer { withExtendedLifetime(lock) {} }
        return try body(lock)
    }

    @discardableResult
    public static func withLibraryLock<T>(
        root: URL, timeout: TimeInterval = VPhoneLibraryLock.defaultTimeout, _ body: (VPhoneLibraryLock) throws -> T
    ) throws -> T {
        try live.withLibraryLock(root: root, timeout: timeout, body)
    }

    // MARK: Cooperative DFU verification

    /// Confirms that the bundle is held by a live DFU boot of *this* bundle,
    /// and returns that holder's record.
    ///
    /// `restore` drives a device that only exists while a DFU boot runs, so it
    /// must work on a locked bundle. Taking the lock is therefore impossible
    /// and the holder is verified instead. The runtime record alone proves
    /// nothing (it is never deleted and can name a reused pid), so the pid it
    /// names is checked against the kernel and against `ps`: it must exist, not
    /// be a zombie, and still be a `vphone-cli --config <this bundle>` process.
    @discardableResult
    public func requireDFUOwner(directory: URL, configURL: URL) throws -> VPhoneVMRuntimeState {
        let name = Self.bundleName(directory)
        guard lockHeld(directory) else {
            throw VPhoneBundleGuardError.dfuSessionRequired(
                bundle: name,
                detail: "nothing holds its bundle lock; start the DFU boot first (vphone-cli vm launch --dfu)")
        }
        guard let record = readRecord(directory) else {
            throw VPhoneBundleGuardError.dfuSessionRequired(
                bundle: name,
                detail: "its bundle lock is held but the runtime record is missing or unreadable")
        }
        guard record.isDFUOperation else {
            var detail = "it is held by pid \(record.pid) running operation \"\(record.operation)\""
            if record.isBootOperation {
                detail += " (instance \(record.instanceID)); stop the VM and boot it with --dfu first"
            } else {
                detail += "; wait for that operation to finish, then boot with --dfu"
            }
            throw VPhoneBundleGuardError.dfuSessionRequired(bundle: name, detail: detail)
        }
        guard let holder = identity(record.pid), !holder.isZombie else {
            throw VPhoneBundleGuardError.dfuSessionRequired(
                bundle: name,
                detail: "the runtime record names DFU pid \(record.pid), which is no longer running")
        }
        guard bootPIDs(configURL).contains(record.pid) else {
            throw VPhoneBundleGuardError.dfuSessionRequired(
                bundle: name,
                detail: "pid \(record.pid) is not a vphone-cli --config process for this bundle")
        }
        return record
    }

    @discardableResult
    public static func requireDFUOwner(directory: URL, configURL: URL) throws -> VPhoneVMRuntimeState {
        try live.requireDFUOwner(directory: directory, configURL: configURL)
    }

    // MARK: Refusal wording

    /// Why the lock could not be taken, in the wording `VPhoneVMStopper` uses
    /// for the same situation. A record that names a dead pid says nothing
    /// about the current holder, so it is not reported as one.
    func holderDetail(directory: URL) -> String {
        guard let record = readRecord(directory),
              let holder = identity(record.pid), !holder.isZombie
        else {
            return "another operation holds its bundle lock; if the VM is running, stop the VM first"
        }
        var detail = "it is held by pid \(record.pid) running operation \"\(record.operation)\""
        if record.isBootOperation {
            detail += " (instance \(record.instanceID)); stop the VM first"
        }
        return detail
    }

    static func bundleName(_ directory: URL) -> String {
        directory.standardizedFileURL.lastPathComponent
    }
}

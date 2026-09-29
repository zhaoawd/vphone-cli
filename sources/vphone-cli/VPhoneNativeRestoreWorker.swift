import ArgumentParser
import Darwin
import Foundation
import VPhoneCore
import VPhoneRestore

enum VPhoneNativeRestoreOperation: String, CaseIterable, ExpressibleByArgument {
    case probe
    case ticket
    case restore

    var timeout: TimeInterval {
        switch self {
        case .probe: 30
        case .ticket: 300
        case .restore: 1800
        }
    }
}

/// A separate CLI process contains the C restore library's global state and
/// stdout capture. It can be terminated without killing the create runner.
struct VPhoneNativeRestoreWorker: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-restore-worker", shouldDisplay: false)

    @Option var bundle: String
    @Option var ecid: String
    @Option var udid: String
    @Option var instanceID: String
    @Option var parentPID: Int32
    @Option var operation: VPhoneNativeRestoreOperation

    func run() throws {
        guard parentPID > 1, getppid() == parentPID else {
            throw ValidationError("native restore worker requires its supervising parent")
        }
        // The supervisor temporarily ignores these signals and consumes them
        // via Dispatch. Reset the dispositions inherited across exec.
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        let directory = URL(fileURLWithPath: bundle).standardizedFileURL
        let target = try Self.validateIdentity(directory: directory, ecid: ecid, udid: udid)
        let owner = try VPhoneBundleGuard.requireDFUOwner(
            directory: directory, configURL: directory.appendingPathComponent("config.plist"))
        guard owner.instanceID == instanceID else {
            throw ValidationError("DFU instance changed before native restore")
        }
        // Separate from the VM's directory lock, which the DFU owner holds.
        let lockPath = directory.appendingPathComponent(".native-restore.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG else {
            throw ValidationError("native restore lock is not a regular file")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw ValidationError("another native restore worker holds this bundle")
        }
        guard getppid() == parentPID else { throw CancellationError() }

        // A hard-killed supervisor must not leave an unattended device writer.
        let parent = parentPID
        let monitor = DispatchSource.makeTimerSource(queue: .global())
        monitor.schedule(deadline: .now(), repeating: .milliseconds(250))
        monitor.setEventHandler { if getppid() != parent { _exit(125) } }
        monitor.resume()
        defer { monitor.cancel() }
        let sink: VPhoneRestoreEventHandler = { event in
            if case let .log(_, message) = event {
                FileHandle.standardError.write(Data((message.trimmingCharacters(in: .newlines) + "\n").utf8))
            }
        }
        switch operation {
        case .probe:
            let device = try VPhoneRestoreService.recoveryProbe(ecid: target, timeout: 20)
            guard device.ecid == target else { throw ValidationError("native probe returned a different ECID") }
        case .ticket:
            try VPhoneRestoreService.fetchSHSH(vmDir: directory, ecid: target, udid: udid, out: nil, onEvent: sink)
        case .restore:
            try VPhoneRestoreService.restore(vmDir: directory, ecid: target, udid: udid, erase: true,
                                             ticketPath: nil, onEvent: sink)
        }
    }

    static func validateIdentity(directory: URL, ecid: String, udid: String) throws -> UInt64 {
        guard let target = try VPhoneRestoreIdentity.parseECID(ecid), target != 0 else {
            throw ValidationError("native restore requires a nonzero ECID")
        }
        let (recordedUDID, recordedECID) = try VPhoneCreateOrchestrator.readDeviceIdentity(bundleURL: directory, wait: 0)
        guard UInt64(recordedECID, radix: 16) == target,
              VPhoneRestoreIdentity.normalizeUDID(udid) == VPhoneRestoreIdentity.normalizeUDID(recordedUDID)
        else { throw ValidationError("native restore target differs from this bundle's device identity") }
        return target
    }
}

enum VPhoneNativeRestoreProcess {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    // Signal dispositions are process-wide; only one supervisor may own them.
    private static let supervisionLock = NSLock()

    static func run(executable: URL, bundle: URL, ecid: String, udid: String,
                    instanceID: String, operation: VPhoneNativeRestoreOperation, echo: Bool) throws {
        let arguments = ["native-restore-worker", "--bundle", bundle.path, "--ecid", ecid,
                         "--udid", udid, "--instance-id", instanceID, "--parent-pid", "\(getpid())",
                         "--operation", operation.rawValue]
        try supervise(executable: executable, arguments: arguments, cwd: bundle,
                      timeout: operation.timeout, echo: echo)
    }

    static func supervise(executable: URL, arguments: [String], cwd: URL, timeout: TimeInterval,
                          echo: Bool, shouldCancel: () -> Bool = { false }) throws {
        guard supervisionLock.try() else { throw ValidationError("native restore supervisor is already active") }
        defer { supervisionLock.unlock() }
        let cancelled = Cancellation()
        let oldINT = signal(SIGINT, SIG_IGN)
        let oldTERM = signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { cancelled.cancel() }
            source.resume()
            return source
        }
        defer {
            sources.forEach { $0.cancel() }
            signal(SIGINT, oldINT)
            signal(SIGTERM, oldTERM)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        if !echo {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, !cancelled.isCancelled, !shouldCancel(), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let wasCancelled = cancelled.isCancelled || shouldCancel()
        let timedOut = process.isRunning && !wasCancelled
        if process.isRunning {
            process.interrupt()
            let grace = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 5
            while process.isRunning, ProcessInfo.processInfo.systemUptime < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
            guard !process.isRunning else { throw ValidationError("native restore worker did not exit; recovery required") }
        }
        if wasCancelled { throw CancellationError() }
        if timedOut { throw ValidationError("native restore worker timed out after \(Int(timeout)) seconds") }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ValidationError("native restore worker failed (exit \(process.terminationStatus))")
        }
    }
}

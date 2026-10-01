import Darwin
import Foundation

/// A started child process whose merged stdout and stderr arrive line by line
/// on a background thread.
///
/// Two output modes:
/// - A pipe, for commands that finish (`vm list --json`, `vm stop`). Output
///   ends when every holder of the pipe has closed it.
/// - A log file, for `vm launch`. The machine must outlive Launchpad: with a
///   pipe, quitting the app would close the read end and the next line of
///   guest serial output would end `vm launch` with SIGPIPE. The child gets
///   its own session, stdin on /dev/null and stdout and stderr appended to
///   the file; the file is tailed while the app runs and stays behind as the
///   machine's console log. The child is also made responsible for itself
///   (disclaim), so macOS does not attribute it to Launchpad after the app
///   quits.
public final class VPhoneLaunchpadChildProcess: @unchecked Sendable {
    private let process = Process()
    /// Set instead of `process` for a detached child.
    private var detachedPID: pid_t?
    private let lock = NSLock()
    private var exitStatus: Int32?
    /// The detached child has exited. Set under `lock` while the child is
    /// still an unreaped zombie, so `interrupt()` can never reach a reused PID.
    private var hasExited = false
    private var exitCode: Int32 = 0
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    /// Starts `executable`. With `logFile`, the child is detached and writes
    /// to a new, empty file at that path (an earlier log there is replaced).
    init(
        executable: URL,
        arguments: [String],
        logFile: URL? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        if let logFile {
            try FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A new file, not a truncated one: a follower still reading the
            // previous run sees the file number change and starts over.
            guard FileManager.default.createFile(atPath: logFile.path, contents: nil) else {
                throw VPhoneLaunchpadError("Cannot create \(logFile.path)")
            }
            let reader = try FileHandle(forReadingFrom: logFile)
            let pid = try Self.spawnDetached(executable: executable, arguments: arguments, logFile: logFile)
            detachedPID = pid
            Thread.detachNewThread { [self] in
                reap(pid)
            }
            Thread.detachNewThread { [self] in
                tail(reader, onLine)
            }
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let reader = pipe.fileHandleForReading
            Thread.detachNewThread { [self] in
                VPhoneLaunchpadLineReader.readLines(from: reader, onLine: onLine)
                process.waitUntilExit()
                finish(process.terminationStatus)
            }
        }
    }

    public var processIdentifier: pid_t {
        detachedPID ?? process.processIdentifier
    }

    public var isDetached: Bool {
        detachedPID != nil
    }

    public var isRunning: Bool {
        lock.withLock { exitStatus == nil }
    }

    /// The exit status, once the process has exited and its output drained:
    /// the exit code, or the number of the signal that ended it.
    public func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// SIGINT, which `vphone-cli` treats as a graceful stop. Only ever sent to
    /// this object's own child, and only while it has not exited. False when
    /// nothing was sent.
    @discardableResult
    public func interrupt() -> Bool {
        if let detachedPID {
            lock.lock()
            defer { lock.unlock() }
            guard !hasExited else {
                return false
            }
            return kill(detachedPID, SIGINT) == 0
        }
        guard process.isRunning else {
            return false
        }
        return kill(process.processIdentifier, SIGINT) == 0
    }

    // MARK: - Detached child

    /// Waits for the detached child without reaping it, marks it exited,
    /// then reaps it. Between the two the PID still names the zombie, so a
    /// concurrent `interrupt()` cannot reach another process.
    private func reap(_ pid: pid_t) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        var status: Int32 = 0
        lock.withLock {
            hasExited = true
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            exitCode = Self.exitCode(status)
        }
    }

    /// Follows the log file until the child has exited and everything it
    /// wrote is read.
    private func tail(_ reader: FileHandle, _ onLine: (String) -> Void) {
        var splitter = VPhoneLaunchpadLineSplitter()
        while true {
            let exited = lock.withLock { hasExited }
            if let chunk = try? reader.readToEnd(), !chunk.isEmpty {
                splitter.feed(chunk, onLine)
            }
            if exited {
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        splitter.flush(onLine)
        try? reader.close()
        finish(lock.withLock { exitCode })
    }

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// Starts `executable` in a new session, responsible for itself, with
    /// stdin on /dev/null and stdout and stderr appended to `logFile`. No other
    /// descriptor of Launchpad's is inherited.
    static func spawnDetached(executable: URL, arguments: [String], logFile: URL) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default dispositions and an empty mask: an ignored SIGINT would be
        // inherited across exec, and `vm stop` and `interrupt()` rely on it.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // The private libSystem call Chromium and LLDB use for the same
        // purpose; looked up at run time, as upstream does.
        if let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logFile.path, O_WRONLY | O_APPEND, 0)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
        return pid
    }

    /// The same number `Process.terminationStatus` reports: the exit code, or
    /// the signal that ended the process.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : signal
    }

    private func finish(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: status)
        }
    }
}

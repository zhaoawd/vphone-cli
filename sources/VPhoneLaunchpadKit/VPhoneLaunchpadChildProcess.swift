import Foundation

/// A started child process whose merged stdout and stderr arrive line by line
/// on a background thread, through a pipe. Output ends when every holder of
/// the pipe has closed it.
///
/// B1 only runs commands that finish (`vm list --json`). The detached,
/// log-file mode upstream uses for `vm launch` arrives with start and stop in
/// B2.
public final class VPhoneLaunchpadChildProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
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

    public var isRunning: Bool {
        lock.withLock { exitStatus == nil }
    }

    /// The exit status, once the process has exited and its output drained.
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
    /// this object's own child while `Process` reports it running.
    public func interrupt() {
        if process.isRunning {
            kill(process.processIdentifier, SIGINT)
        }
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

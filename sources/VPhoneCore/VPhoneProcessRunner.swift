import Darwin
import Foundation

// MARK: - VPhoneProcessResult

public struct VPhoneProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    /// True when the deadline expired while waiting for the child or its output.
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

// MARK: - VPhoneProcessRunner

public enum VPhoneProcessRunner {
    /// Thread-safe accumulator for a pipe's bytes. `@unchecked Sendable`
    /// because access is serialized by its lock, satisfying the readability
    /// handler's `@Sendable` requirement under Swift 6 strict concurrency.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func take() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Run `executable args` to completion, capturing stdout/stderr.
    /// Throws only if the process cannot be launched; a nonzero exit is
    /// returned in the result, not thrown.
    ///
    /// Both output pipes are drained concurrently (readability handlers without
    /// a timeout, nonblocking polling with one), so a full stderr pipe cannot
    /// deadlock a child while the caller waits for stdout to reach EOF.
    ///
    /// With `timeout`, stdin is `/dev/null`. The deadline covers both the child
    /// and its output pipes. SIGTERM is followed by SIGKILL after 250 ms; pipe
    /// draining and exit observation stop within one second of the deadline.
    public static func runCapturing(
        _ executable: URL,
        _ args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> VPhoneProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let env { process.environment = env }
        if let timeout {
            return try runCapturingBounded(process, timeout: timeout)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; group.leave() }
            else { outBox.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; group.leave() }
            else { errBox.append(chunk) }
        }

        try process.run()
        process.waitUntilExit()
        group.wait()

        return VPhoneProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outBox.take(), as: UTF8.self),
            stderr: String(decoding: errBox.take(), as: UTF8.self))
    }

    /// Poll on the calling thread so deadlines cannot queue behind blocking
    /// work on Dispatch's global pool. Nonblocking reads also bound capture
    /// when a descendant inherits a pipe after the direct child has exited.
    private static func runCapturingBounded(_ process: Process, timeout: TimeInterval) throws -> VPhoneProcessResult {
        let pipes = [Pipe(), Pipe()]
        defer {
            for pipe in pipes {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        var descriptors = try pipes.map { pipe -> pollfd in
            let fd = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipes[0]
        process.standardError = pipes[1]
        try process.run()
        for pipe in pipes { try? pipe.fileHandleForWriting.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var output = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 65536)
        var timedOut = false
        var killed = false
        while process.isRunning || descriptors.contains(where: { $0.fd >= 0 }) {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline, !timedOut {
                timedOut = true
                if process.isRunning { process.terminate() }
            }
            if timedOut, now >= deadline + 0.25, !killed {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                killed = true
            }
            if timedOut, now >= deadline + 1 { break }
            _ = poll(&descriptors, nfds_t(descriptors.count), 10)
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = read(descriptors[index].fd, &buffer, buffer.count)
                if count > 0 {
                    output[index].append(contentsOf: buffer[..<count])
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    descriptors[index].fd = -1
                }
            }
        }
        return VPhoneProcessResult(
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            stdout: String(decoding: output[0], as: UTF8.self),
            stderr: String(decoding: output[1], as: UTF8.self), timedOut: timedOut)
    }

    /// Stream an archive through a `/usr/bin/tar` consumer that reads on stdin,
    /// invoking `onBytes` with the running byte total so a caller can drive a
    /// progress bar off the *uncompressed* (export) or *compressed* (import)
    /// stream. The byte source is exactly one of:
    ///   - `producerArgs`: a `tar` producing an uncompressed archive to a pipe
    ///     (export → count uncompressed input; the consumer compresses via `@-`).
    ///   - `sourceFile`: the archive file read directly (import → count the file
    ///     as it is fed into `tar -x`).
    /// Returns the stderr of whichever stage exited nonzero (consumer first), or
    /// `nil` on success. SIGPIPE is ignored for the duration so a consumer that
    /// dies early surfaces as its exit status rather than killing this process.
    public static func runCountingTarPipe(
        producerArgs: [String]?,
        sourceFile: URL?,
        consumerArgs: [String],
        onBytes: ((Int64) -> Void)? = nil
    ) throws -> String? {
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let prevPIPE = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, prevPIPE) }

        let group = DispatchGroup()

        let consumer = Process()
        consumer.executableURL = tar
        consumer.arguments = consumerArgs
        let cIn = Pipe()
        consumer.standardInput = cIn
        consumer.standardOutput = FileHandle.nullDevice
        let cErr = Pipe()
        consumer.standardError = cErr
        let cErrBox = DataBox()
        group.enter()
        cErr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; group.leave() }
            else { cErrBox.append(chunk) }
        }

        var producer: Process?
        let source: FileHandle
        let pErrBox = DataBox()
        if let producerArgs {
            let p = Process()
            p.executableURL = tar
            p.arguments = producerArgs
            let pOut = Pipe()
            p.standardOutput = pOut
            let pErr = Pipe()
            p.standardError = pErr
            group.enter()
            pErr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; group.leave() }
                else { pErrBox.append(chunk) }
            }
            producer = p
            source = pOut.fileHandleForReading
        } else if let sourceFile {
            source = try FileHandle(forReadingFrom: sourceFile)
        } else {
            preconditionFailure("runCountingTarPipe: producerArgs or sourceFile required")
        }

        try consumer.run()
        try producer?.run()

        let sink = cIn.fileHandleForWriting
        var total: Int64 = 0
        while true {
            guard let chunk = try? source.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            do { try sink.write(contentsOf: chunk) } catch { break }  // consumer died; status below
            total += Int64(chunk.count)
            onBytes?(total)
        }
        try? sink.close()
        try? source.close()

        producer?.waitUntilExit()
        consumer.waitUntilExit()
        group.wait()

        if consumer.terminationStatus != 0 {
            return String(decoding: cErrBox.take(), as: UTF8.self)
        }
        if let producer, producer.terminationStatus != 0 {
            return String(decoding: pErrBox.take(), as: UTF8.self)
        }
        return nil
    }

    /// Run `executable args`, inheriting the parent's stdout/stderr so output
    /// streams live to the terminal (for long-running tools: downloads, restore,
    /// CFW install). Returns the child's exit status; throws only on spawn failure.
    /// When `echo` is false, the child's stdout/stderr are redirected to the null
    /// device so nothing reaches the terminal; the exit status is still returned.
    public static func runStreaming(
        _ executable: URL,
        _ args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        echo: Bool = true
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let env { process.environment = env }

        if !echo {
            let devNull = FileHandle.nullDevice
            process.standardOutput = devNull
            process.standardError = devNull
        }
        // When echo is true: no pipe redirection → child inherits our stdio (live streaming).

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Run `executable args` as a controlling-terminal FOREGROUND job.
    ///
    /// Foundation spawns children in a new process group, which leaves them in
    /// the *background* of the terminal — an interactive program they run (e.g.
    /// `sudo`) then can't disable echo or read the tty (the password shows and
    /// isn't delivered). This hands the terminal to the child's group via
    /// `tcsetpgrp` for the duration, so sudo owns the tty and reads the password
    /// directly; our process never sees it. Our foreground group is restored on
    /// return. Falls back to a plain inherited run when there is no tty.
    public static func runForeground(
        _ executable: URL,
        _ args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        echo: Bool = true
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let env { process.environment = env }
        // When echo is false, suppress the child's normal output — but it still
        // becomes the terminal's foreground group below, so an interactive sudo
        // it runs still prompts/reads via /dev/tty (independent of stdout/stderr).
        if !echo {
            let devNull = FileHandle.nullDevice
            process.standardOutput = devNull
            process.standardError = devNull
        }

        var ttyFD = FileHandle.standardInput.fileDescriptor
        var openedTTY = false
        if isatty(ttyFD) == 0 {
            let fd = open("/dev/tty", O_RDWR)
            guard fd >= 0 else {
                try process.run(); process.waitUntilExit(); return process.terminationStatus
            }
            ttyFD = fd
            openedTTY = true
        }

        let savedFg = tcgetpgrp(ttyFD)
        // tcsetpgrp from a background group would raise SIGTTOU/SIGTTIN (default:
        // stop). Ignore them while we juggle the foreground group.
        let prevTTOU = signal(SIGTTOU, SIG_IGN)
        let prevTTIN = signal(SIGTTIN, SIG_IGN)
        defer {
            signal(SIGTTOU, prevTTOU)
            signal(SIGTTIN, prevTTIN)
            if openedTTY { close(ttyFD) }
        }

        try process.run()
        _ = tcsetpgrp(ttyFD, process.processIdentifier)   // hand the tty to the child
        process.waitUntilExit()
        if savedFg > 0 { _ = tcsetpgrp(ttyFD, savedFg) }  // take it back
        return process.terminationStatus
    }

    /// Run `executable args` as root via macOS's native auth dialog (`osascript` →
    /// `do shell script … with administrator privileges`). `do shell script` runs
    /// under a bare env, so `env` is passed inline as `KEY=value` — nothing else
    /// reaches the command. Returns the command's exit status.
    public static func runWithAdminPrivileges(
        _ executable: URL, _ args: [String], env: [String: String] = [:], echo: Bool = true
    ) throws -> Int32 {
        func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var tokens = env.sorted { $0.key < $1.key }.map { "\($0.key)=\(shQuote($0.value))" }
        tokens.append(shQuote(executable.path))
        tokens += args.map(shQuote)
        var command = tokens.joined(separator: " ")
        if echo, isatty(STDOUT_FILENO) != 0, let tty = ttyname(STDOUT_FILENO) {
            command += " > \(shQuote(String(cString: tty))) 2>&1"
        }
        // Escape the /bin/sh command for the AppleScript string literal (\ then ").
        let appleEscaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(appleEscaped)\" with administrator privileges"
        return try runStreaming(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source], echo: echo)
    }
}

import Foundation
import Observation

// MARK: - Errors

public struct VPhoneLaunchpadError: LocalizedError, Sendable {
    public let message: String
    public var detail: String?

    public init(_ message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    public var errorDescription: String? {
        message
    }

    public var failureReason: String? {
        detail
    }
}

// MARK: - Result

public struct VPhoneLaunchpadCommandResult: Sendable {
    public let status: Int32
    public let lines: [String]
    public let outputDrained: Bool
    /// Lines omitted from the bounded display list; the detached raw log is separate.
    public let omittedLineCount: Int

    public init(status: Int32, lines: [String], outputDrained: Bool = true, omittedLineCount: Int = 0) {
        self.status = status
        self.lines = lines
        self.outputDrained = outputDrained
        self.omittedLineCount = omittedLineCount
    }

    public var succeeded: Bool {
        status == 0 && outputDrained
    }

    /// The last few lines, which is where `vphone-cli` reports what failed.
    public var tail: String {
        lines.suffix(12).joined(separator: "\n")
    }

    /// The JSON document in the output.
    ///
    /// stderr is merged into the same stream, so warnings (`vm list` prints
    /// `warning: skipping ...` for an unreadable bundle) can precede it. Only
    /// the document's opening bracket sits at column zero, so the last line
    /// that opens a document starts it, and it runs to the end of the output.
    public var jsonData: Data? {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("[") || $0.hasPrefix("{") }) else {
            return nil
        }
        return Data(lines[start...].joined(separator: "\n").utf8)
    }
}

// MARK: - History

/// How Recent Commands shows a command's exit status.
public enum VPhoneLaunchpadCommandOutcome: Equatable, Sendable {
    case running
    case succeeded
    /// A non-zero status the command defines as a warning (`doctor` exits 3
    /// when its worst finding is a warning).
    case warning
    case failed
}

/// Every command Launchpad runs, shown so it can be copied into a terminal
/// (Recent Commands). The periodic `vm list` is not recorded.
@MainActor
@Observable
public final class VPhoneLaunchpadCommandHistory {
    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let date = Date()
        public let text: String
        /// Non-zero statuses that mean "finished with warnings", not failure.
        public var warningStatuses: Set<Int32> = []
        public var status: Int32?
        public var outputDrained: Bool?

        /// Running until it exits; 0 succeeded; a warning status is a
        /// warning; any other status failed.
        public var outcome: VPhoneLaunchpadCommandOutcome {
            guard let status else {
                return .running
            }
            if outputDrained == false { return .failed }
            if status == 0 {
                return .succeeded
            }
            return warningStatuses.contains(status) ? .warning : .failed
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public func record(_ text: String, warningStatuses: Set<Int32> = []) -> UUID {
        let entry = Entry(text: text, warningStatuses: warningStatuses)
        entries.append(entry)
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
        return entry.id
    }

    public func finish(_ id: UUID, status: Int32, outputDrained: Bool = true) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].status = status
            entries[index].outputDrained = outputDrained
        }
    }
}

// MARK: - vphone-cli

/// Runs the embedded `vphone-cli` by absolute path. Nothing here goes through
/// a shell or `$PATH`.
@MainActor
public struct VPhoneLaunchpadCommandLine {
    public let executable: URL
    public let history: VPhoneLaunchpadCommandHistory
    private let logsDirectory: URL?

    /// The only public way in: a verified embedded toolchain.
    public init(toolchain: VPhoneLaunchpadToolchain, history: VPhoneLaunchpadCommandHistory) {
        self.init(executable: toolchain.executable, history: history, logsDirectory: VPhoneLaunchpadIdentity.logsDirectory())
    }

    /// Test seam for stand-in executables; not reachable from the app.
    init(executable: URL, history: VPhoneLaunchpadCommandHistory, logsDirectory: URL? = nil) {
        self.logsDirectory = logsDirectory
        self.executable = executable
        self.history = history
    }

    public nonisolated static func display(_ arguments: [String]) -> String {
        (["vphone-cli"] + arguments.map(quoted)).joined(separator: " ")
    }

    private nonisolated static func quoted(_ argument: String) -> String {
        let plain = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=,@+".contains($0) }
        return plain && !argument.isEmpty ? argument : "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Runs to completion. Cancelling the calling task sends SIGINT to this
    /// child. `onLine` runs on the reader thread, never on the main actor.
    /// `warningStatuses` only changes how Recent Commands shows the exit.
    public func run(
        _ arguments: [String],
        recordInHistory: Bool = true,
        warningStatuses: Set<Int32> = [],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> VPhoneLaunchpadCommandResult {
        let writer = try recordInHistory ? logsDirectory.map { try VPhoneLaunchpadLogWriter(url: $0.appendingPathComponent("command-\(UUID().uuidString).log")) } : nil
        let entry = recordInHistory ? history.record(Self.display(arguments), warningStatuses: warningStatuses) : nil
        let collector = VPhoneLaunchpadLineCollector()
        let child: VPhoneLaunchpadChildProcess
        do {
            child = try VPhoneLaunchpadChildProcess(executable: executable, arguments: arguments) { line in
                writer?.write(line)
                collector.append(line)
                onLine?(line)
            }
        } catch {
            try? await writer?.finish()
            if let entry { history.finish(entry, status: -1, outputDrained: false) }
            throw error
        }
        let completion = await withTaskCancellationHandler {
            await child.waitForCompletion()
        } onCancel: {
            child.interrupt()
        }
        var drained = completion.outputDrained
        do { try await writer?.finish() }
        catch { drained = false; collector.append("Log persistence failed: \(error.localizedDescription)") }
        if let entry {
            history.finish(entry, status: completion.status, outputDrained: drained)
        }
        let output = collector.snapshot
        return VPhoneLaunchpadCommandResult(status: completion.status, lines: output.lines,
            outputDrained: drained, omittedLineCount: output.omitted)
    }

    /// Starts a long-running command (`vm launch`) and returns at once. Its
    /// output goes to `logFile`, so it outlives Launchpad. `onLine` runs on
    /// the reader thread: a guest console can print faster than the main
    /// actor should wake for. `preamble` is written at the top of the new log.
    public func start(
        _ arguments: [String],
        logFile: URL,
        preamble: String? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> VPhoneLaunchpadChildProcess {
        let entry = history.record(Self.display(arguments))
        let child = try VPhoneLaunchpadChildProcess(
            executable: executable, arguments: arguments, logFile: logFile, preamble: preamble, onLine: onLine)
        let history = history
        Task {
            let completion = await child.waitForCompletion()
            history.finish(entry, status: completion.status, outputDrained: completion.outputDrained)
        }
        return child
    }
}

/// Collects output lines from the reader thread, keeping the most recent.
final class VPhoneLaunchpadLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var omitted = 0

    func append(_ line: String) {
        lock.withLock {
            storage.append(line)
            if storage.count > 4000 {
                omitted += storage.count - 4000
                storage.removeFirst(storage.count - 4000)
            }
        }
    }

    var lines: [String] { snapshot.lines }

    var snapshot: (lines: [String], omitted: Int) {
        lock.withLock { (storage, omitted) }
    }
}

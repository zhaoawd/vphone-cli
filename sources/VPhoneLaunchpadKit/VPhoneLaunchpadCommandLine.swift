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

    public init(status: Int32, lines: [String]) {
        self.status = status
        self.lines = lines
    }

    public var succeeded: Bool {
        status == 0
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

/// Every command Launchpad runs, shown so it can be copied into a terminal.
/// The history view arrives in B3; B1 records into it.
@MainActor
@Observable
public final class VPhoneLaunchpadCommandHistory {
    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let date = Date()
        public let text: String
        public var status: Int32?
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public func record(_ text: String) -> UUID {
        let entry = Entry(text: text)
        entries.append(entry)
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
        return entry.id
    }

    public func finish(_ id: UUID, status: Int32) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].status = status
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

    /// The only public way in: a verified embedded toolchain.
    public init(toolchain: VPhoneLaunchpadToolchain, history: VPhoneLaunchpadCommandHistory) {
        self.init(executable: toolchain.executable, history: history)
    }

    /// Test seam for stand-in executables; not reachable from the app.
    init(executable: URL, history: VPhoneLaunchpadCommandHistory) {
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
    public func run(
        _ arguments: [String],
        recordInHistory: Bool = true,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> VPhoneLaunchpadCommandResult {
        let entry = recordInHistory ? history.record(Self.display(arguments)) : nil
        let collector = VPhoneLaunchpadLineCollector()
        let child = try VPhoneLaunchpadChildProcess(executable: executable, arguments: arguments) { line in
            collector.append(line)
            onLine?(line)
        }
        let status = await withTaskCancellationHandler {
            await child.wait()
        } onCancel: {
            child.interrupt()
        }
        if let entry {
            history.finish(entry, status: status)
        }
        return VPhoneLaunchpadCommandResult(status: status, lines: collector.lines)
    }
}

/// Collects output lines from the reader thread, keeping the most recent.
final class VPhoneLaunchpadLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock {
            storage.append(line)
            if storage.count > 4000 {
                storage.removeFirst(storage.count - 4000)
            }
        }
    }

    var lines: [String] {
        lock.withLock { storage }
    }
}

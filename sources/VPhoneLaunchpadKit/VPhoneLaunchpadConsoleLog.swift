import Darwin
import Foundation

// MARK: - Console lines

/// What Launchpad reads from, and adds to, a machine's console log.
public enum VPhoneLaunchpadConsoleLog {
    /// Upstream's pattern (`VPhoneLaunchpadCreationPipeline.panicPattern`):
    /// a kernel panic, the panic report host, or the stackshot line a panic
    /// prints. Case-insensitive.
    public static let panicPattern = #"(^|[^p])(panic|kernel panic|panic\.apple\.com|stackshot succeeded)"#

    public static func isPanic(_ line: String) -> Bool {
        line.range(of: panicPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The line Launchpad appends once a `vm launch` it started has exited.
    public static func exitLine(status: Int32) -> String {
        "vm launch exited with status \(status)"
    }

    /// Appends one line of Launchpad's own to `log`, after the process that
    /// wrote it has exited. Starts on a new line, since the last output line
    /// may lack its newline. Does nothing when the log is missing.
    public static func append(_ line: String, to log: URL) {
        guard let handle = try? FileHandle(forWritingTo: log) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\n\(line)\n".utf8))
    }
}

// MARK: - Follower

/// Follows a log file by polling: the writer may be a process an earlier
/// Launchpad session started, so there is no pipe to read.
///
/// Each `poll()` reads what was appended since the last one and returns it
/// as display lines (`VPhoneLaunchpadLineSplitter`: `\r` and `\n` end a
/// line, ANSI escapes are dropped). When the file is replaced (another file
/// number) or truncated below the read offset, it returns `.reset` and
/// starts over from the last `replayBytes` of the file, skipping the partial
/// line there.
public struct VPhoneLaunchpadLogFollower: Sendable {
    public enum Event: Equatable, Sendable {
        /// The file does not exist yet. Reported once.
        case missing
        /// Discard what was shown: the file was replaced or truncated, or it
        /// appeared after `.missing`.
        case reset
        case lines([String])
    }

    /// How much of an existing log the viewer replays when it opens.
    public static let defaultReplayBytes: UInt64 = 4 << 20
    static let chunkBytes = 1 << 20

    public let url: URL
    let replayBytes: UInt64
    private var file: UInt64?
    private var offset: UInt64 = 0
    private var splitter = VPhoneLaunchpadLineSplitter()
    private var reportedMissing = false
    /// Set after a restart in the middle of the file, until its first
    /// newline has been read.
    private var skipsPartialLine = false

    public init(url: URL) {
        self.init(url: url, replayBytes: Self.defaultReplayBytes)
    }

    init(url: URL, replayBytes: UInt64) {
        self.url = url
        self.replayBytes = replayBytes
    }

    public mutating func poll() -> [Event] {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let handle = try? FileHandle(forReadingFrom: url)
        else {
            if file == nil, !reportedMissing {
                reportedMissing = true
                return [.missing]
            }
            return []
        }
        defer { try? handle.close() }
        var events: [Event] = []
        let number = UInt64(info.st_ino)
        let size = UInt64(info.st_size)
        if file != number || size < offset {
            if file != nil || reportedMissing {
                events.append(.reset)
            }
            file = number
            offset = size > replayBytes ? size - replayBytes : 0
            skipsPartialLine = offset > 0
            splitter = VPhoneLaunchpadLineSplitter()
        }
        var lines: [String] = []
        try? handle.seek(toOffset: offset)
        while var chunk = try? handle.read(upToCount: Self.chunkBytes), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            if skipsPartialLine {
                guard let end = chunk.firstIndex(of: 0x0A) else {
                    continue
                }
                chunk = chunk[chunk.index(after: end)...]
                skipsPartialLine = false
            }
            splitter.feed(chunk) { lines.append($0) }
        }
        if !lines.isEmpty {
            events.append(.lines(lines))
        }
        return events
    }
}

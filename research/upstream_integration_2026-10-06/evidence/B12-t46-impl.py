from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');d=r/'sources/VPhoneLaunchpadKit'
p=d/'VPhoneLaunchpadLineReader.swift';s=p.read_text();s=s.replace('''    public static func readLines(from handle: FileHandle, onLine: (String) -> Void) {
        var splitter = VPhoneLaunchpadLineSplitter()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            splitter.feed(chunk, onLine)
        }
        splitter.flush(onLine)
    }
''','''    public enum Completion: Equatable, Sendable { case drained, failed }

    @discardableResult
    public static func readLines(from handle: FileHandle, onLine: (String) -> Void) -> Completion {
        var splitter = VPhoneLaunchpadLineSplitter()
        defer { splitter.flush(onLine) }
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                splitter.feed(chunk, onLine)
            }
            return .drained
        } catch {
            return .failed
        }
    }
''');p.write_text(s)
p=d/'VPhoneLaunchpadChildProcess.swift';s=p.read_text();s=s.replace('''    private var exitStatus: Int32?
''','''    private var exitStatus: Int32?
    private var outputDrained = false

    public struct Completion: Sendable {
        public let status: Int32
        /// All bytes available to this reader reached the synchronous callback.
        /// This does not acknowledge an asynchronous writer or XPC helper.
        public let outputDrained: Bool
    }
''');s=s.replace('''                VPhoneLaunchpadLineReader.readLines(from: reader, onLine: onLine)
                process.waitUntilExit()
                finish(process.terminationStatus)
''','''                let output = VPhoneLaunchpadLineReader.readLines(from: reader, onLine: onLine)
                process.waitUntilExit()
                finish(process.terminationStatus, outputDrained: output == .drained)
''');needle='''    /// SIGINT, which `vphone-cli` treats as a graceful stop.''';s=s.replace(needle,'''    public func waitForCompletion() async -> Completion {
        let status = await wait()
        return lock.withLock { Completion(status: status, outputDrained: outputDrained) }
    }

'''+needle)
s=s.replace('''        var splitter = VPhoneLaunchpadLineSplitter()
        while true {
            let exited = lock.withLock { hasExited }
            if let chunk = try? reader.readToEnd(), !chunk.isEmpty {
                splitter.feed(chunk, onLine)
            }
''','''        var splitter = VPhoneLaunchpadLineSplitter()
        var readFailed = false
        while true {
            let exited = lock.withLock { hasExited }
            if !readFailed {
                do {
                    if let chunk = try reader.readToEnd(), !chunk.isEmpty {
                        splitter.feed(chunk, onLine)
                    }
                } catch { readFailed = true }
            }
''');s=s.replace('''        finish(lock.withLock { exitCode })''','''        finish(lock.withLock { exitCode }, outputDrained: !readFailed)''');s=s.replace('''    private func finish(_ status: Int32) {
        lock.lock()
        exitStatus = status
''','''    private func finish(_ status: Int32, outputDrained: Bool) {
        lock.lock()
        self.outputDrained = outputDrained
        exitStatus = status
''');p.write_text(s)
p=d/'VPhoneLaunchpadCommandLine.swift';s=p.read_text();s=s.replace('''    public let lines: [String]

    public init(status: Int32, lines: [String]) {
        self.status = status
        self.lines = lines
    }

    public var succeeded: Bool {
        status == 0
''','''    public let lines: [String]
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
''');s=s.replace('''        public var status: Int32?
''','''        public var status: Int32?
        public var outputDrained: Bool?
''');s=s.replace('''            if status == 0 {
                return .succeeded
''','''            if status == 0 {
                return outputDrained == false ? .failed : .succeeded
''');s=s.replace('''    public func finish(_ id: UUID, status: Int32) {''','''    public func finish(_ id: UUID, status: Int32, outputDrained: Bool = true) {''');s=s.replace('''            entries[index].status = status
''','''            entries[index].status = status
            entries[index].outputDrained = outputDrained
''');s=s.replace('''        let status = await withTaskCancellationHandler {
            await child.wait()
''','''        let completion = await withTaskCancellationHandler {
            await child.waitForCompletion()
''');s=s.replace('''            history.finish(entry, status: status)
        }
        return VPhoneLaunchpadCommandResult(status: status, lines: collector.lines)
''','''            history.finish(entry, status: completion.status, outputDrained: completion.outputDrained)
        }
        let output = collector.snapshot
        return VPhoneLaunchpadCommandResult(status: completion.status, lines: output.lines,
            outputDrained: completion.outputDrained, omittedLineCount: output.omitted)
''');s=s.replace('''            let status = await child.wait()
            history.finish(entry, status: status)
''','''            let completion = await child.waitForCompletion()
            history.finish(entry, status: completion.status, outputDrained: completion.outputDrained)
''');s=s.replace('''    private var storage: [String] = []
''','''    private var storage: [String] = []
    private var omitted = 0
''');s=s.replace('''                storage.removeFirst(storage.count - 4000)
''','''                omitted += storage.count - 4000
                storage.removeFirst(storage.count - 4000)
''');s=s.replace('''    var lines: [String] {
        lock.withLock { storage }
''','''    var snapshot: (lines: [String], omitted: Int) {
        lock.withLock { (storage, omitted) }
''');p.write_text(s)

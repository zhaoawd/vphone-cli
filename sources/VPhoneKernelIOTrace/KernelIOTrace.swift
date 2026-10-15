import Darwin
import Foundation

/// Opt-in measurements only. No trace file I/O occurs before flush/normal exit.
public enum KernelIOTrace {
    private static let recorder: KernelIORecorder = {
        let value = KernelIORecorder(outputPrefix: ProcessInfo.processInfo.environment["VPHONE_KERNEL_IO_TRACE"])
        if value.enabled { atexit { KernelIOTrace.flush() } }
        return value
    }()

    /// Synchronous spans are inclusive; parent/child durations must not be added.
    public static func measure<T>(_ phase: String, labels: [String: String] = [:],
                                  aggregateChildren: Bool = false, aggregate: Bool = false,
                                  file: String = #fileID, line: Int = #line, function: String = #function,
                                  _ body: (KernelIOSpan?) throws -> T) rethrows -> T {
        try recorder.measure(phase, labels: labels, aggregateChildren: aggregateChildren, aggregate: aggregate,
                             file: file, line: line, function: function, body)
    }

    /// Only the original syscall and two clock reads are in the fsync interval.
    /// Preserve errno before all trace bookkeeping, including on success.
    public static func synchronize(_ fd: Int32, phase: String = "fsync",
                                   file: String = #fileID, line: Int = #line, function: String = #function) -> Int32 {
        let entryErrno = errno
        let activeRecorder = recorder
        errno = entryErrno
        return activeRecorder.synchronize(fd, phase: phase, file: file, line: line, function: function)
    }

    public static func labels(_ url: URL, byteSemantics: String) -> [String: String] {
        guard recorder.enabled else { return [:] }
        let role: String
        switch url.lastPathComponent {
        case "Disk.img": role = "live_disk"
        case "kernel-disk-original.img": role = "original_disk_snapshot"
        case "kernel-disk-candidate.img": role = "candidate_disk_snapshot"
        case "kernel-candidate.img", "candidate.img": role = "candidate_image"
        case "kernel-disk-interrupted.bin": role = "interrupted_block"
        default: role = url.path.contains("/.firmware-generations/") ? "generation_original" : "file"
        }
        return ["role": role, "path_basename": url.lastPathComponent, "byte_semantics": byteSemantics]
    }

    /// Normally invoked only by atexit, after the complete business operation.
    private static func flush() { recorder.flush() }
}

/// Counters belong to the current synchronous call. Never share across threads.
public final class KernelIOSpan {
    let id = UUID().uuidString.lowercased()
    let parentID: String?
    let phase: String
    let labels: [String: String]
    let file: String, line: Int, function: String
    let threadID: UInt64
    let aggregateChildren: Bool
    var counts: [String: Int64] = [:]
    var observedErrorType: String?
    var started: UInt64 = 0
    init(phase: String, labels: [String: String], parentID: String?, file: String, line: Int, function: String, aggregateChildren: Bool) {
        self.phase = phase; self.labels = labels; self.parentID = parentID
        self.file = file; self.line = line; self.function = function; self.aggregateChildren = aggregateChildren
        threadID = UInt64(pthread_mach_thread_np(pthread_self()))
    }
    public func set(_ name: String, _ value: Int64) { counts[name] = value }
    public func recordFailure(_ type: String) { observedErrorType = type }
    func aggregate(_ phase: String, elapsed: UInt64, success: Bool) {
        let prefix = "aggregate." + phase + "."
        counts[prefix + "calls", default: 0] += 1
        counts[prefix + "elapsed_ns", default: 0] += Int64(clamping: elapsed)
        counts[prefix + (success ? "success" : "error"), default: 0] += 1
    }
}

struct KernelIOEvent: Encodable, Sendable {
    let type = "span", schema_version = 1
    let id: String, parent_id: String?
    let pid: Int32, thread_id: UInt64
    let phase: String, caller_file: String, caller_line: Int, caller_function: String
    let started_ns: UInt64, elapsed_ns: UInt64
    let inclusive = true
    let outcome: String, error_type: String?
    let counts: [String: Int64], labels: [String: String]
}

final class KernelIORecorder: @unchecked Sendable {
    let enabled: Bool
    private let prefix: String?
    private let stackKey: String
    private let maximumEvents: Int
    private let lock = NSLock()
    private var events: [KernelIOEvent] = []
    private var dropped = 0, openSpans = 0
    private var incomplete = false, flushed = false
    init(outputPrefix: String?, maximumEvents: Int = 100_000) {
        enabled = outputPrefix != nil
        stackKey = outputPrefix == nil ? "" : "vphone.kernel-io-trace." + UUID().uuidString
        prefix = outputPrefix
        self.maximumEvents = maximumEvents
        if let outputPrefix, !outputPrefix.hasPrefix("/") || outputPrefix.isEmpty { incomplete = true }
    }
    private var stack: [KernelIOSpan] {
        get { Thread.current.threadDictionary[stackKey] as? [KernelIOSpan] ?? [] }
        set { Thread.current.threadDictionary[stackKey] = newValue }
    }
    private func append(_ event: KernelIOEvent) {
        lock.lock(); defer { lock.unlock() }
        if events.count < maximumEvents { events.append(event) }
        else { dropped += 1; incomplete = true }
    }
    func measure<T>(_ phase: String, labels: [String: String] = [:], aggregateChildren: Bool = false, aggregate: Bool = false,
                    file: String = #fileID, line: Int = #line, function: String = #function,
                    _ body: (KernelIOSpan?) throws -> T) rethrows -> T {
        guard enabled else { return try body(nil) }
        if aggregate, let parent = stack.last(where: { $0.aggregateChildren }) {
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                let result = try body(nil)
                let end = DispatchTime.now().uptimeNanoseconds
                parent.aggregate(phase, elapsed: end - start, success: true)
                return result
            } catch {
                let end = DispatchTime.now().uptimeNanoseconds
                parent.aggregate(phase, elapsed: end - start, success: false)
                throw error
            }
        }
        let span = KernelIOSpan(phase: phase, labels: labels, parentID: stack.last?.id, file: file, line: line, function: function, aggregateChildren: aggregateChildren)
        var current = stack; current.append(span); stack = current
        lock.lock(); openSpans += 1; lock.unlock()
        span.started = DispatchTime.now().uptimeNanoseconds
        var outcome = "success", errorType: String?
        defer {
            let end = DispatchTime.now().uptimeNanoseconds
            var current = stack
            if current.last?.id == span.id { current.removeLast(); stack = current }
            else { lock.lock(); incomplete = true; lock.unlock() }
            append(KernelIOEvent(id: span.id, parent_id: span.parentID, pid: getpid(), thread_id: span.threadID,
                                 phase: phase, caller_file: file, caller_line: line, caller_function: function,
                                 started_ns: span.started, elapsed_ns: end - span.started, outcome: span.observedErrorType == nil ? outcome : "error",
                                 error_type: errorType ?? span.observedErrorType, counts: span.counts, labels: labels))
            lock.lock(); openSpans -= 1; lock.unlock()
        }
        do { return try body(span) }
        catch { outcome = "error"; errorType = String(reflecting: type(of: error)); throw error }
    }
    func synchronize(_ fd: Int32, phase: String, file: String, line: Int, function: String) -> Int32 {
        let entryErrno = errno
        guard enabled else { return Darwin.fsync(fd) }
        let parent = stack.last
        let aggregate = stack.last(where: { $0.aggregateChildren })
        let start = DispatchTime.now().uptimeNanoseconds
        errno = entryErrno
        let result = Darwin.fsync(fd)
        let savedErrno = errno
        let end = DispatchTime.now().uptimeNanoseconds
        if let aggregate { aggregate.aggregate(phase, elapsed: end - start, success: result == 0) }
        else {
            append(KernelIOEvent(id: UUID().uuidString.lowercased(), parent_id: parent?.id, pid: getpid(),
                                 thread_id: UInt64(pthread_mach_thread_np(pthread_self())), phase: phase,
                                 caller_file: file, caller_line: line, caller_function: function,
                                 started_ns: start, elapsed_ns: end - start, outcome: result == 0 ? "success" : "error",
                                 error_type: result == 0 ? nil : "POSIXError", counts: ["calls": 1], labels: result == 0 ? ["byte_semantics": "unknown"] : ["byte_semantics": "unknown", "error_code": String(savedErrno)]))
        }
        errno = savedErrno
        return result
    }
    /// Memory collection is bounded. A missing/false terminal footer rejects a run.
    func flush() {
        guard enabled else { return }
        lock.lock()
        guard !flushed else { lock.unlock(); return }
        flushed = true
        let snapshot = events, lost = dropped, active = openSpans
        let valid = !incomplete && active == 0
        lock.unlock()
        var failure: String?
        do {
            guard let prefix, prefix.hasPrefix("/"), !prefix.isEmpty else { throw POSIXError(.EINVAL) }
            let fd = Darwin.open(prefix + ".\(getpid()).jsonl", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(fd) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            func write(_ data: Data) throws {
                try data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if amount < 0, errno == EINTR { continue }
                        guard amount > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        offset += amount
                    }
                }
            }
            for event in snapshot { var data = try encoder.encode(event); data.append(10); try write(data) }
            let footer: [String: Any] = ["type": "measurement_end", "schema_version": 1, "pid": getpid(), "complete": valid,
                                         "events": snapshot.count, "dropped": lost, "open_spans": active, "io_error": NSNull()]
            var data = try JSONSerialization.data(withJSONObject: footer, options: [.sortedKeys]); data.append(10); try write(data)
        } catch { failure = String(reflecting: type(of: error)) }
        if failure != nil || !valid {
            let message = "[kernel-io-trace] measurement incomplete: " + (failure ?? "dropped events or unfinished spans") + "\n"
            _ = message.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
        }
    }
}

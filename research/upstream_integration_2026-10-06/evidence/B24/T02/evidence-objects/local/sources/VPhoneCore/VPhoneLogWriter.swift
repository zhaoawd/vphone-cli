import Darwin
import Foundation

/// Each operation owns one writer. finish seals the input, waits for queued
/// batches, synchronizes and closes the file before acknowledging completion.
public final class VPhoneLogWriter: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.vphone.cli.launchpad.log-writer")
    private let lock = NSLock()
    private var pending = Data()
    private var scheduled = false
    private var sealed = false
    private var closed = false // accessed on queue only
    private var failure: Error?
    private var recent: [String] = []

    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        self.init(url: url, handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    package init(url: URL, handle: FileHandle) { self.url = url; self.handle = handle }

    public func write(_ line: String) {
        lock.withLock {
            guard !sealed else {
                failure = failure ?? NSError(domain: "VPhoneLogWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output arrived after log completion"])
                return
            }
            recent.append(line)
            if recent.count > 12 { recent.removeFirst(recent.count - 12) }
            pending.append(contentsOf: line.utf8)
            pending.append(10)
            guard !scheduled else { return }
            scheduled = true
            // Schedule under the lock so finish cannot overtake this batch.
            queue.async { [self] in
                let data = lock.withLock {
                    let bytes = pending
                    pending = Data()
                    scheduled = false
                    return bytes
                }
                do { try handle.write(contentsOf: data) }
                catch { lock.withLock { failure = failure ?? error } }
            }
        }
    }

    public var tail: String { lock.withLock { recent.joined(separator: "\n") } }

    public func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                sealed = true
                queue.async { [self] in
                    if !closed {
                        do { try handle.synchronize(); try handle.close() }
                        catch { lock.withLock { failure = failure ?? error }; try? handle.close() }
                        closed = true
                    }
                    let error = lock.withLock { failure }
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }
}

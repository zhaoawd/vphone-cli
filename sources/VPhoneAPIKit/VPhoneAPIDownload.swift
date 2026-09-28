import Darwin
import Foundation

/// A bounded, private staged download. Releasing it removes unpublished bytes.
/// Publication is exclusive and must be on the same filesystem as staging.
public final class VPhoneAPIDownload: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let file: URL
    private var handle: FileHandle?
    private var count = 0
    private var complete = false
    public var size: Int { lock.withLock { count } }

    init(directory parent: URL) throws {
        var template = Array(parent.appendingPathComponent(".vphone-download-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw Self.ioError() }
        directory = URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
        file = directory.appendingPathComponent("content")
        let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw Self.ioError() }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    deinit { try? handle?.close(); try? FileManager.default.removeItem(at: directory) }

    func append(_ data: Data, maximumBytes: Int) throws {
        try lock.withLock {
            guard !complete, let handle else { throw Self.ioError() }
            guard data.count <= maximumBytes - count else {
                throw VPhoneAPIError(code: "file_too_large", message: "Download exceeds byte limit")
            }
            do { try handle.write(contentsOf: data) } catch { throw Self.ioError() }
            count += data.count
        }
    }

    func finish(expectedBytes: Int64) throws {
        try lock.withLock {
            guard expectedBytes < 0 || expectedBytes == Int64(count) else {
                throw VPhoneAPIError(code: "protocol", message: "Incomplete file response")
            }
            do { try handle?.synchronize(); try handle?.close() } catch { throw Self.ioError() }
            handle = nil
            complete = true
        }
    }

    func uploadFile() throws -> URL {
        try lock.withLock {
            guard complete else { throw Self.ioError() }
            return file
        }
    }

    public func data() throws -> Data {
        try lock.withLock {
            guard complete, count <= 1024 * 1024 else {
                throw VPhoneAPIError(code: "file_too_large", message: "Inline download exceeds 1 MiB")
            }
            do { return try Data(contentsOf: file) } catch { throw Self.ioError() }
        }
    }

    public func publish(to destination: URL) throws {
        try lock.withLock {
            guard complete, destination.isFileURL else { throw Self.ioError() }
            // renamex_np atomically rejects files, directories and symlinks
            // already occupying the destination; no check-then-replace race.
            guard renamex_np(file.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw VPhoneAPIError(code: "destination_exists", message: "Destination already exists") }
                throw Self.ioError()
            }
            complete = false
        }
    }

    private static func ioError() -> VPhoneAPIError {
        VPhoneAPIError(code: "file_io", message: "Host download file operation failed")
    }
}

/// Streams URLSession chunks directly to disk. No response-sized Data buffer.
final class VPhoneAPIFileExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let instanceID: String
    private let binaryHash: String
    private var download: VPhoneAPIDownload?
    private var continuation: CheckedContinuation<VPhoneAPIDownload, any Error>?
    private var task: URLSessionDataTask?
    private var timer: DispatchWorkItem?
    private var completed = false
    private var accepted = false
    private var expectedBytes: Int64 = -1

    init(download: VPhoneAPIDownload, maximumBytes: Int, instanceID: String, binaryHash: String) {
        self.download = download
        self.maximumBytes = maximumBytes
        self.instanceID = instanceID
        self.binaryHash = binaryHash
    }

    func run(_ request: URLRequest, session: URLSession, timeout: TimeInterval) async throws -> VPhoneAPIDownload {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                task.delegate = self
                let timer = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(VPhoneAPIError(code: "timeout", message: "Download deadline exceeded")))
                }
                let started = lock.withLock {
                    guard !completed else { return false }
                    self.continuation = continuation
                    self.task = task
                    self.timer = timer
                    task.resume()
                    return true
                }
                if started { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer) }
                else { task.cancel(); continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw VPhoneAPIError(code: "http", message: "File HTTP request failed")
            }
            guard UUID(uuidString: http.value(forHTTPHeaderField: "X-Vphone-Instance-ID") ?? "") == UUID(uuidString: instanceID),
                  http.value(forHTTPHeaderField: "X-Vphone-Binary-Hash") == binaryHash else {
                throw VPhoneAPIError(code: "identity_mismatch", message: "File response identity mismatch")
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard contentType == "application/octet-stream",
                  [nil, "identity"].contains(http.value(forHTTPHeaderField: "Content-Encoding")) else {
                throw VPhoneAPIWire.invalidEnvelope()
            }
            guard response.expectedContentLength <= maximumBytes else {
                throw VPhoneAPIError(code: "file_too_large", message: "Download exceeds byte limit")
            }
            let active = lock.withLock {
                guard !completed else { return false }
                expectedBytes = response.expectedContentLength
                accepted = true
                return true
            }
            completionHandler(active ? .allow : .cancel)
        } catch { finish(.failure(error)); completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try lock.withLock {
                guard !completed, accepted else { return }
                try download?.append(data, maximumBytes: maximumBytes)
            }
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        do {
            let result = try lock.withLock {
                guard !completed else { return nil as VPhoneAPIDownload? }
                guard accepted, let download else { throw VPhoneAPIWire.invalidEnvelope() }
                try download.finish(expectedBytes: expectedBytes)
                return download
            }
            if let result { finish(.success(result)) }
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func finish(_ result: Result<VPhoneAPIDownload, any Error>) {
        let saved = lock.withLock { () -> (CheckedContinuation<VPhoneAPIDownload, any Error>?, URLSessionTask?) in
            guard !completed else { return (nil, nil) }
            completed = true
            let saved = (continuation, task)
            continuation = nil
            task = nil
            timer?.cancel()
            timer = nil
            download = nil
            return saved
        }
        saved.1?.cancel()
        saved.0?.resume(with: result)
    }
}

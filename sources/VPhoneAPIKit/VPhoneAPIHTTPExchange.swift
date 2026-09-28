import Foundation

/// Collects bounded chunks instead of iterating AsyncBytes one byte at a time.
/// The same lock arbitrates completion, the absolute deadline and cancellation.
final class VPhoneAPIHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response: Sendable { let data: Data; let status: Int }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Response, any Error>?
    private var task: URLSessionDataTask?
    private var timer: DispatchWorkItem?
    private var completed = false
    private var status: Int?
    private var data = Data()

    func run(_ request: URLRequest, session: URLSession, timeout: TimeInterval) async throws -> Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                task.delegate = self
                let timer = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(VPhoneAPIError(
                        code: "timeout", message: "API deadline exceeded; guest operation may continue")))
                }
                let started = lock.withLock {
                    guard !completed else { return false }
                    self.continuation = continuation
                    self.task = task
                    self.timer = timer
                    // Resume under the lock so a concurrent cancellation cannot
                    // cancel and then accidentally restart this task.
                    task.resume()
                    return true
                }
                if started {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                } else {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(VPhoneAPIError(code: "transport", message: "Missing HTTP response")))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= VPhoneAPIWire.maximumResponseBytes else {
            finish(.failure(Self.tooLarge()))
            completionHandler(.cancel)
            return
        }
        let active = lock.withLock {
            guard !completed else { return false }
            status = http.statusCode
            return true
        }
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let overflow = lock.withLock {
            guard !completed else { return false }
            guard chunk.count <= VPhoneAPIWire.maximumResponseBytes - data.count else { return true }
            data.append(chunk)
            return false
        }
        if overflow { finish(.failure(Self.tooLarge())) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        let response = lock.withLock { status.map { Response(data: data, status: $0) } }
        if let response { finish(.success(response)) }
        else { finish(.failure(VPhoneAPIError(code: "transport", message: "Missing HTTP response"))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func finish(_ result: Result<Response, any Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<Response, any Error>?, URLSessionDataTask?) in
            guard !completed else { return (nil, nil) }
            completed = true
            let saved = (continuation, task)
            continuation = nil
            task = nil
            timer?.cancel()
            timer = nil
            data = Data()
            return saved
        }
        state.1?.cancel()
        state.0?.resume(with: result)
    }

    private static func tooLarge() -> VPhoneAPIError {
        VPhoneAPIError(code: "response_too_large", message: "API message exceeds 8 MiB")
    }
}

import Foundation

/// An explicit HTTP endpoint client. This library does not create a listener,
/// connect to VSOCK, install a daemon, or change the classic guest protocol.
public struct VPhoneAPIClient: Sendable {
    public let baseURL: URL
    private let token: String?
    private let session: URLSession
    private let timeout: TimeInterval

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared,
                timeout: TimeInterval = 30) throws {
        guard let url = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(url.scheme), url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              timeout.isFinite, timeout > 0, timeout <= 130 else {
            throw VPhoneAPIError(code: "configuration", message: "Invalid API endpoint or timeout")
        }
        if let token {
            guard (16...256).contains(token.utf8.count), token.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [45, 46, 95, 126].contains($0)
            }) else {
                throw VPhoneAPIError(code: "configuration", message: "Invalid API token")
            }
        }
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.timeout = timeout
    }

    public func health(requiredCapabilities: Set<String> = [], expectedBinaryHash: String? = nil) async throws -> VPhoneAPIHealth {
        let (data, status) = try await exchange(request(path: "v1/health"))
        guard status == 200 else { throw httpError(status) }
        return try VPhoneAPIHealth.decode(data, requiredCapabilities: requiredCapabilities, expectedBinaryHash: expectedBinaryHash)
    }

    public func call(_ method: String, params: [String: VPhoneJSONValue] = [:]) async throws -> VPhoneJSONValue {
        let id = UUID().uuidString
        var request = request(path: "v1/rpc")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try VPhoneAPIWire.request(method, params: params, id: id)
        let (data, status) = try await exchange(request)
        guard case let .response(response) = try VPhoneAPIWire.message(data), response.id == .string(id) else {
            throw VPhoneAPIWire.invalidEnvelope()
        }
        if let error = response.error { throw error }
        guard status == 200 else { throw httpError(status) }
        return try VPhoneAPIWire.result(response)
    }

    /// Each socket has its own generation and pending requests. Call close()
    /// when finished; create a new socket after a disconnect instead of reusing it.
    public func openWebSocket() -> VPhoneAPIWebSocket {
        let task = session.webSocketTask(with: webSocketRequest())
        task.maximumMessageSize = VPhoneAPIWire.maximumResponseBytes
        task.delegate = VPhoneAPINoRedirect.shared
        task.resume()
        return VPhoneAPIWebSocket(transport: VPhoneURLSessionWebSocket(task: task), timeout: timeout)
    }

    func webSocketRequest() -> URLRequest {
        var request = request(path: "v1/events")
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        request.url = url.url!
        return request
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func exchange(_ request: URLRequest) async throws -> (Data, Int) {
        let result = try await VPhoneAPIHTTPExchange().run(request, session: session, timeout: timeout)
        return (result.data, result.status)
    }

    private func httpError(_ status: Int) -> VPhoneAPIError {
        VPhoneAPIError(code: "http", message: "API returned HTTP \(status)")
    }
}

/// Credentials must not be forwarded to a redirected endpoint.
private final class VPhoneAPINoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = VPhoneAPINoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

import Darwin
import Foundation

/// Local fixture server for the saved shell regression. Never uses a guest.
final class MethodsLiveStubServer: @unchecked Sendable {
    let scenario: [String: Any]
    let callLog: String
    let token: String
    let logLock = NSLock()
    var seen: [String: Int] = [:]

    init(arguments: [String]) throws {
        scenario = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[1]))) as! [String: Any]
        callLog = arguments[2]
        token = arguments[4]
    }

    func handle(_ client: Int32) {
        defer { close(client) }
        do {
            var received = Data()
            let boundary = Data("\r\n\r\n".utf8)
            var buffer = [UInt8](repeating: 0, count: 8192)
            while received.range(of: boundary) == nil {
                let count = read(client, &buffer, buffer.count)
                guard count > 0, received.count < 1_048_576 else { return }
                received.append(contentsOf: buffer.prefix(count))
            }
            let headerEnd = received.range(of: boundary)!.upperBound
            let header = String(decoding: received[..<headerEnd], as: UTF8.self)
            let fields = header.components(separatedBy: "\r\n").dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let headers = Dictionary(fields, uniquingKeysWith: { first, _ in first })
            guard headers["authorization"] == "Bearer " + token else {
                send(client, status: 401, body: Data("{}".utf8)); return
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard (0 ... 1_048_576).contains(length) else { return }
            while received.count - headerEnd < length {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { return }
                received.append(contentsOf: buffer.prefix(count))
            }
            let body = received.subdata(in: headerEnd ..< headerEnd + length)
            let request = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            let method = request["method"] as? String ?? ""
            logLock.lock()
            do {
                let file = try FileHandle(forWritingTo: URL(fileURLWithPath: callLog))
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: Data((method + "\n").utf8))
                logLock.unlock()
            } catch { logLock.unlock(); throw error }
            guard let entry = nextEntry(for: method) else {
                try sendJSON(client, status: 400, ["type": "response", "error": ["code": "unknown_method", "message": "Unknown method"]]); return
            }
            if entry["drop"] != nil { return }
            if let delay = entry["stall"] as? Double { Thread.sleep(forTimeInterval: delay); return }
            if let raw = entry["raw"] as? String { send(client, status: 200, body: Data(raw.utf8)); return }
            if let value = entry["json"] { try sendJSON(client, status: entry["status"] as? Int ?? 200, value); return }
            if let error = entry["error"] { try sendJSON(client, status: 400, ["type": "response", "error": error]); return }
            if let size = entry["pad"] as? Int {
                let prefix = "{\"type\":\"response\",\"result\":{\"a\":\"", suffix = "\"}}"
                send(client, status: 200, body: Data((prefix + String(repeating: "x", count: max(0, size - prefix.utf8.count - suffix.utf8.count)) + suffix).utf8)); return
            }
            try sendJSON(client, status: 200, ["type": "response", "id": "1", "result": entry["result"] ?? NSNull()])
        } catch { send(client, status: 500, body: Data("{}".utf8)) }
    }

    func nextEntry(for method: String) -> [String: Any]? {
        logLock.lock()
        defer { logLock.unlock() }
        guard let value = scenario[method] else { return nil }
        if let replies = value as? [[String: Any]] {
            guard !replies.isEmpty else { return nil }
            let index = seen[method, default: 0]
            seen[method] = index + 1
            return replies[min(index, replies.count - 1)]
        }
        return value as? [String: Any]
    }

    func sendJSON(_ client: Int32, status: Int, _ object: Any) throws {
        send(client, status: status, body: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
    }

    func send(_ client: Int32, status: Int, body: Data) {
        var response = Data("HTTP/1.1 \(status) Fixture\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        response.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}

@main enum MethodsLiveStubMain {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 5)
        signal(SIGPIPE, SIG_IGN)
        let server = try MethodsLiveStubServer(arguments: arguments)
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        precondition(socketFD >= 0)
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(bound == 0 && listen(socketFD, 16) == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        precondition(withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) }
        } == 0)
        try String(UInt16(bigEndian: address.sin_port)).write(toFile: arguments[3], atomically: true, encoding: .utf8)
        while true {
            let client = accept(socketFD, nil, nil)
            if client < 0 && errno == EINTR { continue }
            guard client >= 0 else { break }
            DispatchQueue.global().async { server.handle(client) }
        }
    }
}

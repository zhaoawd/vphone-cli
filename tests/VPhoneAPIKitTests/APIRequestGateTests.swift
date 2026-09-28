import Foundation
import Testing
@testable import VPhoneAPIKit

struct APIRequestGateTests {
    let token = "1234567890abcdef"
    func request(_ headers: String = "", target: String = "/v1/rpc", body: Data = Data()) -> Data {
        Data("POST \(target) HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\(headers)\r\n".utf8) + body
    }

    @Test func stripsCredentialsWithoutChangingBody() throws {
        let body = Data([0, 255, 13, 10, 42])
        let input = request("Authorization: Bearer \(token)\r\nContent-Length: 5\r\n", body: body)
        guard case let .accept(output) = VPhoneAPIRequestGate.evaluate(input, token: token) else { Issue.record("Expected admission"); return }
        #expect(output == Data("POST /v1/rpc HTTP/1.1\r\nHost: vphoned\r\nContent-Length: 5\r\n\r\n".utf8) + body)
    }

    @Test func fragmentedHeaderAndExactLimit() {
        let input = request("Authorization: Bearer \(token)\r\n")
        for count in 0..<input.count {
            #expect(VPhoneAPIRequestGate.evaluate(input.prefix(count), token: token) == .needMore)
        }
        let padding = VPhoneAPIRequestGate.maximumHeadLength - input.count - "X: \r\n".utf8.count
        let exact = request("Authorization: Bearer \(token)\r\nX: \(String(repeating: "x", count: padding))\r\n")
        #expect(exact.count == VPhoneAPIRequestGate.maximumHeadLength)
        guard case .accept = VPhoneAPIRequestGate.evaluate(exact, token: token) else { Issue.record("Expected exact limit accepted"); return }
        let oversized = request("Authorization: Bearer \(token)\r\nX: \(String(repeating: "x", count: padding + 1))\r\n")
        #expect(VPhoneAPIRequestGate.evaluate(oversized, token: token) == .reject)
        #expect(VPhoneAPIRequestGate.evaluate(Data(repeating: 65, count: 16384), token: token) == .reject)
    }

    @Test func queryAndSubprotocolTokensAreRemoved() {
        for target in ["/v1/events?token=\(token)&x=1", "/v1/events?%74oken=\(token)&x=1"] {
            guard case let .accept(output) = VPhoneAPIRequestGate.evaluate(request(target: target), token: token) else { Issue.record("Expected query token"); continue }
            let text = String(decoding: output, as: UTF8.self)
            #expect(text.hasPrefix("POST /v1/events?x=1 HTTP/1.1"))
            #expect(!text.contains(token))
        }
        let input = request("Sec-WebSocket-Protocol: vphone-token.\(token), other\r\n")
        guard case let .accept(output) = VPhoneAPIRequestGate.evaluate(input, token: token) else { Issue.record("Expected subprotocol token"); return }
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("Sec-WebSocket-Protocol: other\r\n"))
        #expect(!text.contains(token))
    }

    @Test(arguments: ["Origin: http://localhost\r\n", "Host: localhost\r\n", "Proxy-Authorization: x\r\n",
                      "Content-Length: 1\r\nContent-Length: 1\r\n", "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n",
                      "Content-Length: -1\r\n", "Transfer-Encoding: gzip\r\n", "X: x\nY: y\r\n", " X: x\r\n"])
    func rejectsAmbiguousOrBrowserRequests(header: String) {
        #expect(VPhoneAPIRequestGate.evaluate(request("Authorization: Bearer \(token)\r\n" + header), token: token) == .reject)
    }

    @Test(arguments: ["evil.test", "127.0.0.1.evil.test", "user@localhost", "localhost/path", "localhost?x=1", "localhost:65536"])
    func rejectsNonLocalOrMalformedHost(host: String) {
        let data = Data("GET /v1/health HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8)
        #expect(VPhoneAPIRequestGate.evaluate(data, token: token) == .reject)
    }

    @Test func rejectsMissingWrongAndDuplicateCredentials() {
        #expect(VPhoneAPIRequestGate.evaluate(request(), token: token) == .reject)
        #expect(VPhoneAPIRequestGate.evaluate(request("Authorization: Bearer wrong\r\n"), token: token) == .reject)
        #expect(VPhoneAPIRequestGate.evaluate(request("Authorization: Bearer \(token)\r\n", target: "/v1/events?token=\(token)"), token: token) == .reject)
        #expect(VPhoneAPIRequestGate.evaluate(request("Authorization: Bearer \(token)\r\nAuthorization: Bearer \(token)\r\n"), token: token) == .reject)
        #expect(VPhoneAPIRequestGate.evaluate(request("Authorization: Bearer \(token)\r\n"), token: "") == .reject)
        for target in ["http://localhost/v1/rpc", "//localhost/v1/rpc", "/v1/rpc#x"] {
            #expect(VPhoneAPIRequestGate.evaluate(request("Authorization: Bearer \(token)\r\n", target: target), token: token) == .reject)
        }
        guard case .accept = VPhoneAPIRequestGate.evaluate(request("Authorization: Bearer \(token)\r\n", target: "/v1/rpc?"), token: token) else { Issue.record("Empty query must be safe"); return }
    }
}

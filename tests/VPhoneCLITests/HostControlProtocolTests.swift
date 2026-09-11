import Darwin
import Foundation
import XCTest
import VPhoneCore
@testable import vphone_cli

final class HostControlProtocolTests: XCTestCase {
    private func response(_ request: Data) throws -> [String: Any] {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let server = fds[0]
        let client = fds[1]
        HostControlIO.configure(server)
        HostControlIO.configure(client)
        defer { close(client) }
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            VPhoneHostControl.handleClient(server, controller: nil)
            completed.signal()
        }
        HostControlIO.writeResponse(request + Data([10]), to: client)
        let data = try XCTUnwrap(HostControlIO.readRequest(client))
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInvalidJSONReturnsStableCode() throws {
        XCTAssertEqual(try response(Data("{".utf8))["code"] as? String, "invalid_json")
    }

    func testOversizedInlineFileReturnsStableCode() throws {
        let data = Data(repeating: 0, count: HostControlIO.maximumInlineBytes + 1)
        let request = try JSONSerialization.data(withJSONObject: ["t": "file_put", "path": "/tmp/test", "data_b64": data.base64EncodedString()])
        XCTAssertEqual(try response(request)["code"] as? String, "file_too_large")
    }

    func testRequestBeyond4096BytesReachesCommandHandler() throws {
        let request = try JSONSerialization.data(withJSONObject: ["t": "unknown", "text": String(repeating: "中", count: 3000)])
        let result = try response(request)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertNil(result["code"])
        XCTAssertTrue((result["error"] as? String ?? "").contains("unknown"))
    }
}

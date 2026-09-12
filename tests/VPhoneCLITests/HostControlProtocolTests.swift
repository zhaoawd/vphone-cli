import Darwin
import Foundation
import XCTest
import VPhoneCore
@testable import vphone_cli

final class HostControlProtocolTests: XCTestCase {
    @MainActor private func response(_ request: Data) async throws -> [String: Any] {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let server = fds[0]
        let client = fds[1]
        HostControlIO.configure(server)
        HostControlIO.configure(client)
        defer { close(client) }
        let executor = VPhoneHostCommandExecutor()
        let service = VPhoneHostCommandService(execute: executor.execute)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            VPhoneHostControl.handleClient(server, service: service)
            completed.signal()
        }
        let data = try await Task.detached {
            HostControlIO.writeResponse(request + Data([10]), to: client)
            return try XCTUnwrap(HostControlIO.readRequest(client))
        }.value
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor func testInvalidJSONReturnsStableCode() async throws {
        let result = try await response(Data("{".utf8))
        XCTAssertEqual(result["code"] as? String, "invalid_json")
    }

    @MainActor func testOversizedInlineFileReturnsStableCode() async throws {
        let data = Data(repeating: 0, count: HostControlIO.maximumInlineBytes + 1)
        let request = try JSONSerialization.data(withJSONObject: ["t": "file_put", "path": "/tmp/test", "data_b64": data.base64EncodedString()])
        let result = try await response(request)
        XCTAssertEqual(result["code"] as? String, "file_too_large")
    }

    @MainActor func testRequestBeyond4096BytesReachesCommandHandler() async throws {
        let request = try JSONSerialization.data(withJSONObject: ["t": "unknown", "text": String(repeating: "中", count: 3000)])
        let result = try await response(request)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertNil(result["code"])
        XCTAssertTrue((result["error"] as? String ?? "").contains("unknown"))
    }
    @MainActor func testListeningSocketWorksWithoutViewAndCleansUp() async throws {
        let directory = URL(fileURLWithPath: "/tmp/vp-e2-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("vphone.sock").path
        let server = VPhoneHostControl(socketPath: path, executor: VPhoneHostCommandExecutor())
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        server.start()
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let data = try await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = path.utf8CString
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { target in
                    for (index, byte) in bytes.enumerated() { target[index] = byte }
                }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw CocoaError(.fileReadUnknown) }
            HostControlIO.configure(fd)
            HostControlIO.writeResponse(Data("{\"t\":\"capabilities\"}\n".utf8), to: fd)
            return try XCTUnwrap(HostControlIO.readRequest(fd))
        }.value
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["screen_available"] as? Bool, false)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

}

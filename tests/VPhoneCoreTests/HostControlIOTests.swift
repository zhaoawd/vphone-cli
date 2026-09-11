import Darwin
import Foundation
import XCTest
@testable import VPhoneCore

final class HostControlIOTests: XCTestCase {
    private func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        HostControlIO.configure(fds[0])
        HostControlIO.configure(fds[1])
        return (fds[0], fds[1])
    }

    func testRequestBeyondOldBoundaryAndUTF8() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        let request = Data(("{\"t\":\"type\",\"text\":\"" + String(repeating: "中", count: 2000) + "\"}").utf8)
        HostControlIO.writeResponse(request + Data([10]), to: client)
        XCTAssertEqual(try HostControlIO.readRequest(server), request)
    }

    func testSplitUTF8AndSlowConnectionDeadline() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        let finished = DispatchSemaphore(value: 0)
        let request = Data("{\"t\":\"中\"}\n".utf8)
        DispatchQueue.global().async {
            defer { finished.signal() }
            for byte in request {
                HostControlIO.writeResponse(Data([byte]), to: client)
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        let data = try XCTUnwrap(HostControlIO.readRequest(server))
        XCTAssertEqual(try HostControlIO.decodeRequest(data)["t"] as? String, "中")
        finished.wait()
        DispatchQueue.global().async {
            defer { finished.signal() }
            for _ in 0..<10 {
                HostControlIO.writeResponse(Data([65]), to: client)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        XCTAssertThrowsError(try HostControlIO.readRequest(server, timeout: 0.03)) {
            XCTAssertEqual($0 as? HostControlIO.Failure, .readTimeout)
        }
        finished.wait()
    }

    func testEmptyConnectionAndMalformedJSON() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        XCTAssertThrowsError(try HostControlIO.readRequest(server, timeout: 0.02))
        for data in [Data([255]), Data("[]".utf8), Data("{}".utf8), Data("{".utf8)] {
            XCTAssertThrowsError(try HostControlIO.decodeRequest(data)) {
                XCTAssertEqual($0 as? HostControlIO.Failure, .invalidJSON)
            }
        }
    }

    func testLimitExcludesTerminatorAndFollowingRequests() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        HostControlIO.writeResponse(Data("1234\nignored".utf8), to: client)
        XCTAssertEqual(try HostControlIO.readRequest(server, limit: 4), Data("1234".utf8))
    }

    func testOversizeIsRejectedWithoutEOF() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        HostControlIO.writeResponse(Data("12345".utf8), to: client)
        XCTAssertThrowsError(try HostControlIO.readRequest(server, limit: 4)) {
            XCTAssertEqual($0 as? HostControlIO.Failure, .requestTooLarge)
        }
    }

    func testEOFAndPartialRequestTimeout() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        HostControlIO.writeResponse(Data("{}".utf8), to: client)
        XCTAssertThrowsError(try HostControlIO.readRequest(server, timeout: 0.02)) {
            XCTAssertEqual($0 as? HostControlIO.Failure, .readTimeout)
        }
        shutdown(client, SHUT_WR)
        XCTAssertNil(try HostControlIO.readRequest(server))
    }

    func testEOFCompletesRequest() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        HostControlIO.writeResponse(Data("{}".utf8), to: client)
        shutdown(client, SHUT_WR)
        XCTAssertEqual(try HostControlIO.readRequest(server), Data("{}".utf8))
    }

    func testNonReadingPeerHasWriteDeadline() throws {
        let (server, client) = try pair()
        defer { close(server); close(client) }
        let started = ProcessInfo.processInfo.systemUptime
        HostControlIO.writeResponse(Data(repeating: 65, count: 4 * 1024 * 1024), to: server, timeout: 0.02)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }

    func testFileLimitAndNonRegularFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(HostControlIO.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try HostControlIO.loadFile(url.path)) {
            XCTAssertEqual($0 as? HostControlIO.Failure, .fileTooLarge)
        }
        XCTAssertThrowsError(try HostControlIO.loadFile("/dev/zero"))
    }
}

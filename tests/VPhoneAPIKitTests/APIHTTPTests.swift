import Foundation
import Testing
@testable import VPhoneAPIKit

final class APIHTTPFixture {
    let process = Process()
    let directory: URL
    let port: Int

    init(behindProxy: Bool = false) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vphone-api-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = root.appendingPathComponent(".venv/bin/python3")
        process.arguments = [root.appendingPathComponent("tests/fixtures/host_api/server.py").path, directory.path]
        if behindProxy { process.arguments?.append("--behind-proxy") }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(30)
        var boundPort: Int?
        while ContinuousClock.now < deadline, process.isRunning {
            if let text = try? String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8), let value = Int(text) {
                boundPort = value
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let boundPort else {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
            throw URLError(.cannotConnectToHost)
        }
        port = boundPort
    }

    func client(_ path: String = "", timeout: TimeInterval = 30) throws -> VPhoneAPIClient {
        try VPhoneAPIClient(baseURL: URL(string: "http://127.0.0.1:\(port)/\(path)")!,
                            token: "1234567890abcdef", timeout: timeout)
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
}

struct APIHTTPTests {
    @Test func realHTTPRPCHealthAndProtocolErrors() async throws {
        let fixture = try await APIHTTPFixture()
        defer { fixture.stop() }
        let client = try fixture.client()
        let health = try await client.health(requiredCapabilities: ["files"], expectedBinaryHash: String(repeating: "a", count: 64))
        #expect(health.ios == "26.0")
        #expect(try await client.call("files.list", params: ["path": .string("/中文")]) == .object(["path": .string("/中文")]))
        for (path, expected) in [("wrong", "protocol"), ("error", "denied"), ("status", "http")] {
            do { _ = try await fixture.client(path).call("files.list"); Issue.record("Expected \(expected)") }
            catch let error as VPhoneAPIError { #expect(error.code == expected) }
        }
    }

    @Test func refusesRedirectAndOversizedResponses() async throws {
        let fixture = try await APIHTTPFixture()
        defer { fixture.stop() }
        for (path, code) in [("redirect", "http"), ("large", "response_too_large"), ("chunked-large", "response_too_large")] {
            do { _ = try await fixture.client(path, timeout: 15).health(); Issue.record("Expected \(code)") }
            catch let error as VPhoneAPIError { #expect(error.code == code, "path=\(path)") }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("followed").path))
    }

    @Test func deadlineAndCallerCancellationEndHTTPWait() async throws {
        let fixture = try await APIHTTPFixture()
        defer { fixture.stop() }
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await fixture.client("slow", timeout: 0.05).health() }
        #expect(start.duration(to: .now) < .seconds(1))
        let client = try fixture.client("slow")
        let task = Task { try await client.health() }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func webSocketRefusesRedirect() async throws {
        let fixture = try await APIHTTPFixture()
        defer { fixture.stop() }
        let socket = try fixture.client("redirect").openWebSocket()
        await #expect(throws: (any Error).self) { try await socket.call("one") }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("followed").path))
        await socket.close()
    }

    @Test func realWebSocketUsesBearerAndCorrelatesConcurrentReplies() async throws {
        let fixture = try await APIHTTPFixture()
        defer { fixture.stop() }
        let socket = try fixture.client().openWebSocket()
        async let first = socket.call("first")
        async let second = socket.call("second")
        #expect(try await first == .string("first"))
        #expect(try await second == .string("second"))
        var events = socket.events.makeAsyncIterator()
        #expect(try await events.next()?.event == "connected")
        await socket.close()
    }
}

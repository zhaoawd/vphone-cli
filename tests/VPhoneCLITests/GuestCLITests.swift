import ArgumentParser
import Darwin
import Foundation
import VPhoneCore
import XCTest
@testable import vphone_cli

/// Answers one connection on `<bundle>/vphone.sock` from its own thread with
/// bounded waits (blocking socket I/O stays off the cooperative pool).
private final class GuestStubServer: @unchecked Sendable {
    private let listener: Int32
    private let finished = DispatchGroup()
    private var stopped = false
    private let lock = NSLock()
    private var request = Data()
    var received: Data { lock.withLock { request } }

    init(path: String, reply: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 1) == 0 else { close(fd); throw CocoaError(.fileWriteUnknown) }
        listener = fd
        finished.enter()
        Thread { [self] in
            defer { finished.leave() }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 10_000) > 0 else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var limit = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !data.contains(10) {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[..<count])
            }
            lock.withLock { request = data }
            _ = reply.withCString { write(client, $0, strlen($0)) }
        }.start()
    }

    /// Waits for the server thread, then closes the listener. Idempotent.
    func stop() {
        _ = finished.wait(timeout: .now() + 10)
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            close(listener)
        }
    }
}

final class GuestCLITests: XCTestCase {
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertValidation(_ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertTrue($0 is ValidationError, "unexpected \($0)", file: file, line: line)
        }
    }

    /// Parse errors arrive wrapped by ArgumentParser; compare the printed message.
    private func assertParseError<C: ParsableCommand>(_ type: C.Type, _ args: [String], _ message: String,
                                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try C.parse(args), file: file, line: line) {
            XCTAssertTrue(C.message(for: $0).contains(message), C.message(for: $0), file: file, line: line)
        }
    }

    // MARK: - Parsing

    func testParsesBothSubcommands() throws {
        let send = try VPhoneGuestSendCommand.parse(["vm1", #"{"t":"capabilities"}"#, "--library-root", "/tmp/lib"])
        XCTAssertEqual(send.name, "vm1")
        XCTAssertEqual(send.request, #"{"t":"capabilities"}"#)
        XCTAssertEqual(send.connection.lib.libraryRoot, "/tmp/lib")
        XCTAssertEqual(send.connection.timeout, VPhoneHostCommandService.defaultTimeoutMilliseconds / 1000 + 10)
        XCTAssertEqual(try VPhoneGuestSendCommand.parse(["vm1", "-"]).request, "-")

        let rpc = try VPhoneGuestRPCCommand.parse(["vm1", "device.info", #"{"a":1}"#, "--screen", "--delay", "250",
                                                   "--instance-id", "ID", "--timeout", "7"])
        XCTAssertEqual(rpc.method, "device.info")
        XCTAssertEqual(rpc.params, #"{"a":1}"#)
        XCTAssertTrue(rpc.screen)
        XCTAssertEqual(rpc.delay, 250)
        XCTAssertEqual(rpc.instanceID, "ID")
        XCTAssertEqual(rpc.connection.timeout, 7)

        XCTAssertThrowsError(try VPhoneGuestRPCCommand.parse(["vm1"]))
        XCTAssertThrowsError(try VPhoneGuestSendCommand.parse(["vm1"]))
        for timeout in ["0", "3601"] {
            assertParseError(VPhoneGuestRPCCommand.self, ["vm1", "device.info", "--timeout", timeout], "between 1 and 3600")
        }
        XCTAssertNoThrow(try VPhoneGuestRPCCommand.parse(["vm1", "device.info", "--timeout", "3600"]))
    }

    // MARK: - rpc request

    func testRPCRequestDefaultsAndOptions() throws {
        let plain = try object(VPhoneGuestRequest.rpc(method: "device.info", params: nil, screen: false, delay: nil, target: nil))
        XCTAssertEqual(Set(plain.keys), ["t", "method", "params"])
        XCTAssertEqual(plain["t"] as? String, "rpc")
        XCTAssertEqual(plain["method"] as? String, "device.info")
        XCTAssertEqual((plain["params"] as? [String: Any])?.isEmpty, true)

        let full = try object(VPhoneGuestRequest.rpc(method: "apps.launch", params: #"{"bundle_id":"com.apple.Preferences"}"#,
                                                     screen: true, delay: 0, target: (vm: "vm1", instanceID: "ID")))
        XCTAssertEqual(full["screen"] as? Bool, true)
        XCTAssertEqual(full["delay"] as? Int, 0)
        XCTAssertEqual(full["params"] as? [String: String], ["bundle_id": "com.apple.Preferences"])
        XCTAssertEqual(full["target"] as? [String: String], ["vm": "vm1", "instance_id": "ID"])

        // The command uses the bundle directory name for `target.vm`.
        let command = try VPhoneGuestRPCCommand.parse(["alias", "device.info", "--instance-id", "ID"])
        XCTAssertEqual(try object(command.request(vm: "dir"))["target"] as? [String: String], ["vm": "dir", "instance_id": "ID"])
    }

    func testRPCRequestRejectsBadInput() {
        assertValidation { try VPhoneGuestRequest.rpc(method: "", params: nil, screen: false, delay: nil, target: nil) }
        for params in ["[]", "1", "\"x\"", "{", "null"] {
            assertValidation { try VPhoneGuestRequest.rpc(method: "m", params: params, screen: false, delay: nil, target: nil) }
        }
        assertValidation { try VPhoneGuestRequest.rpc(method: "m", params: nil, screen: false, delay: nil, target: (vm: "v", instanceID: "")) }
        let big = #"{"x":""# + String(repeating: "a", count: HostControlIO.maximumRequestBytes) + #""}"#
        assertValidation { try VPhoneGuestRequest.rpc(method: "m", params: big, screen: false, delay: nil, target: nil) }
        assertParseError(VPhoneGuestRPCCommand.self, ["vm1", "", "--library-root", "/tmp/none"], "method must not be empty")
        assertParseError(VPhoneGuestRPCCommand.self, ["vm1", "m", "[1]"], "params must be a JSON object")
    }

    // MARK: - send request

    func testSendValidation() throws {
        let raw = Data("{\n  \"t\": \"tap\",\n  \"x\": 1.0,\n  \"target\": {\"vm\": \"a\"}\n}\n".utf8)
        let line = try VPhoneGuestRequest.validatedSend(raw)
        XCTAssertFalse(line.contains(10))
        XCTAssertEqual(line, Data("{   \"t\": \"tap\",   \"x\": 1.0,   \"target\": {\"vm\": \"a\"} } ".utf8))
        XCTAssertEqual(try object(line)["t"] as? String, "tap")

        for text in ["[]", "1", "{}", #"{"t":1}"#, #"{"t":null}"#, "{", ""] {
            assertValidation { try VPhoneGuestRequest.validatedSend(Data(text.utf8)) }
        }
        assertValidation { try VPhoneGuestRequest.validatedSend(Data([0x7B, 0xFF, 0x7D])) }
        let limit = HostControlIO.maximumRequestBytes
        let prefix = #"{"t":"x","p":""#
        let fits = prefix + String(repeating: "a", count: limit - prefix.utf8.count - 2) + #""}"#
        XCTAssertEqual(try VPhoneGuestRequest.validatedSend(Data(fits.utf8)).count, limit)
        let over = prefix + String(repeating: "a", count: limit - prefix.utf8.count - 1) + #""}"#
        assertValidation { try VPhoneGuestRequest.validatedSend(Data(over.utf8)) }
        assertParseError(VPhoneGuestSendCommand.self, ["vm1", #"{"x":1}"#], "string \"t\"")
    }

    // MARK: - Output mapping

    func testOutcomeMapping() {
        let ok = Data(#"{"ok":true,"method":"device.info"}"#.utf8)
        XCTAssertEqual(VPhoneGuestOutcome(response: ok), VPhoneGuestOutcome(stdout: ok + Data([10]), stderr: nil, exitCode: 0))

        // Bytes are preserved exactly, including spacing and escaped slashes.
        let rejected = Data(#"{ "ok" : false, "code":"api_timeout","operation_may_continue":true,"p":"a\/b"}"#.utf8)
        XCTAssertEqual(VPhoneGuestOutcome(response: rejected), VPhoneGuestOutcome(stdout: rejected + Data([10]), stderr: nil, exitCode: 1))
        for text in [#"{"error":"x"}"#, #"{"ok":1}"#, #"{"ok":"true"}"#] {
            XCTAssertEqual(VPhoneGuestOutcome(response: Data(text.utf8)).exitCode, 1, text)
        }

        for text in ["[]", "true", "not json", ""] {
            let outcome = VPhoneGuestOutcome(response: Data(text.utf8))
            XCTAssertEqual(outcome.exitCode, 2, text)
            XCTAssertNil(outcome.stdout)
            XCTAssertEqual(outcome.stderr, "error: response is not a JSON object")
        }
    }

    // MARK: - End to end

    func testRPCThroughLibraryBundleAndStubSocket() throws {
        let root = URL(fileURLWithPath: "/tmp/vgc-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("vm1")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try VPhoneVirtualMachineManifest(cpuCount: 4, memorySize: 4 << 30,
            romImages: .init(avpBooter: "AVPBooter.vresearch1.bin", avpSEPBooter: "AVPSEPBooter.vresearch1.bin"))
            .write(to: bundle.appendingPathComponent("config.plist"))

        let args = ["vm1", "device.info", #"{"verbose":true}"#, "--library-root", root.path, "--timeout", "5",
                    "--instance-id", "ID"]
        // No socket yet: exit 2, reason on stderr, nothing on stdout.
        let missing = try VPhoneGuestRPCCommand.parse(args).outcome()
        XCTAssertEqual(missing.exitCode, 2)
        XCTAssertNil(missing.stdout)
        XCTAssertTrue(missing.stderr?.contains("the VM is not running") == true, missing.stderr ?? "")

        let reply = #"{"ok":false,"code":"api_timeout","operation_may_continue":true}"#
        let server = try GuestStubServer(path: bundle.appendingPathComponent("vphone.sock").path, reply: reply + "\n")
        defer { server.stop() }  // idempotent; also covers an early throw
        let outcome = try VPhoneGuestRPCCommand.parse(args).outcome()
        XCTAssertEqual(outcome, VPhoneGuestOutcome(stdout: Data((reply + "\n").utf8), stderr: nil, exitCode: 1))
        server.stop()
        let received = server.received
        XCTAssertEqual(received.last, 10)
        let sent = try object(received.dropLast())
        XCTAssertEqual(sent["method"] as? String, "device.info")
        XCTAssertEqual(sent["params"] as? [String: Bool], ["verbose": true])
        XCTAssertEqual(sent["target"] as? [String: String], ["vm": "vm1", "instance_id": "ID"])

        let unknown = try VPhoneGuestSendCommand.parse(["nope", #"{"t":"capabilities"}"#, "--library-root", root.path]).outcome()
        XCTAssertEqual(unknown, .failure("nope: VM 'nope' not found"))
    }
}

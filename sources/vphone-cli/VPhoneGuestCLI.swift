import ArgumentParser
import Foundation
import VPhoneCore

// MARK: - Command group

/// Client for a running VM's `<bundle>/vphone.sock`. Exit status: 0 for an
/// `ok:true` response, 1 for any other JSON object response (printed
/// unchanged), 2 when no valid response line was obtained.
struct VPhoneGuestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guest",
        abstract: "Send host-control requests to a running VM",
        discussion: """
        Each call opens <bundle>/vphone.sock, sends one JSON request line and
        prints the response line exactly as received.

        Exit status: 0 response has "ok":true; 1 response is a JSON object
        without "ok":true (still printed to stdout); 2 no valid response
        (reason on stderr, nothing on stdout).
        """,
        subcommands: [VPhoneGuestSendCommand.self, VPhoneGuestRPCCommand.self]
    )
}

// MARK: - Shared options

struct VPhoneGuestConnectionOptions: ParsableArguments {
    /// The server's command deadline plus a margin for its 5 s request-read
    /// and 5 s response-write deadlines (E1).
    static let defaultTimeout = VPhoneHostCommandService.defaultTimeoutMilliseconds / 1000 + 10

    @OptionGroup var lib: VPhoneLibraryOption
    @Option(help: "Seconds for connect, send and receive together (1...3600)")
    var timeout: Int = defaultTimeout

    func validate() throws {
        guard (1...3600).contains(timeout) else { throw ValidationError("--timeout must be between 1 and 3600 seconds") }
    }
}

// MARK: - send

struct VPhoneGuestSendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send", abstract: "Send one raw host-control request object")

    @OptionGroup var connection: VPhoneGuestConnectionOptions
    @Argument(help: "VM name") var name: String
    @Argument(help: "Request JSON object with a string \"t\", or - to read it from stdin") var request: String

    func validate() throws {
        if request != "-" { _ = try VPhoneGuestRequest.validatedSend(Data(request.utf8)) }
    }

    func outcome() throws -> VPhoneGuestOutcome {
        let input = request == "-" ? FileHandle.standardInput.readDataToEndOfFile() : Data(request.utf8)
        let payload = try VPhoneGuestRequest.validatedSend(input)
        return VPhoneGuestRequest.perform(payload, vm: name, connection: connection)
    }

    func run() throws { try outcome().emit() }
}

// MARK: - rpc

struct VPhoneGuestRPCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rpc", abstract: "Forward one guest API method through the host-control rpc command",
        discussion: """
        Sends {"t":"rpc","method":...,"params":{...}}. The VM must have been
        started with --api-listen (VPHONE_API_TOKEN set); otherwise the VM
        answers "api_not_ready". --instance-id adds a target of the bundle
        directory name and that instance ID, so a request meant for an earlier
        boot is refused with "target_mismatch".
        """)

    @OptionGroup var connection: VPhoneGuestConnectionOptions
    @Argument(help: "VM name") var name: String
    @Argument(help: "Guest API method, e.g. device.info") var method: String
    @Argument(help: "Params JSON object (default {})") var params: String?
    @Flag(help: "Attach a compact screenshot to a successful response") var screen = false
    @Option(help: "Milliseconds to wait before the --screen capture") var delay: Int?
    @Option(name: .customLong("instance-id"), help: "Refuse unless the socket belongs to this VM boot instance (see capabilities.target)")
    var instanceID: String?

    func validate() throws {
        // Validates method, params and size; `vm` is filled from the bundle in run().
        _ = try request(vm: name)
    }

    func request(vm: String) throws -> Data {
        try VPhoneGuestRequest.rpc(method: method, params: params, screen: screen, delay: delay,
                                   target: instanceID.map { (vm: vm, instanceID: $0) })
    }

    func outcome() throws -> VPhoneGuestOutcome {
        let bundle: VPhoneBundle
        do { bundle = try connection.lib.library.bundle(named: name) } catch {
            return .failure("\(name): \(error)")
        }
        return VPhoneGuestRequest.perform(try request(vm: bundle.url.lastPathComponent), bundle: bundle,
                                          timeout: connection.timeout)
    }

    func run() throws { try outcome().emit() }
}

// MARK: - Request construction and exchange

enum VPhoneGuestRequest {
    static func socketPath(for bundle: VPhoneBundle) -> String {
        bundle.url.appendingPathComponent("vphone.sock").path
    }

    /// Checks a raw request and returns it as one line. JSON strings cannot
    /// hold a raw LF, so every LF is whitespace and becomes a space; all other
    /// bytes (key order, number spelling, a caller's `target`) are kept.
    static func validatedSend(_ input: Data) throws -> Data {
        guard String(data: input, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw ValidationError("request must be one UTF-8 JSON object")
        }
        guard object["t"] is String else { throw ValidationError("request must have a string \"t\"") }
        let line = Data(input.map { $0 == 10 ? 32 : $0 })
        try checkSize(line)
        return line
    }

    static func rpc(method: String, params: String?, screen: Bool, delay: Int?,
                    target: (vm: String, instanceID: String)?) throws -> Data {
        guard !method.isEmpty else { throw ValidationError("method must not be empty") }
        var request: [String: Any] = ["t": "rpc", "method": method, "params": [String: Any]()]
        if let params {
            guard let object = try? JSONSerialization.jsonObject(with: Data(params.utf8)) as? [String: Any] else {
                throw ValidationError("params must be a JSON object")
            }
            request["params"] = object
        }
        if screen { request["screen"] = true }
        if let delay { request["delay"] = delay }
        if let target {
            guard !target.instanceID.isEmpty else { throw ValidationError("--instance-id must not be empty") }
            request["target"] = ["vm": target.vm, "instance_id": target.instanceID]
        }
        let line = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])
        try checkSize(line)
        return line
    }

    private static func checkSize(_ line: Data) throws {
        guard line.count <= HostControlIO.maximumRequestBytes else {
            throw ValidationError("request is \(line.count) bytes; the host-control limit is \(HostControlIO.maximumRequestBytes)")
        }
    }

    static func perform(_ request: Data, vm name: String, connection: VPhoneGuestConnectionOptions) -> VPhoneGuestOutcome {
        do {
            return perform(request, bundle: try connection.lib.library.bundle(named: name), timeout: connection.timeout)
        } catch {
            return .failure("\(name): \(error)")
        }
    }

    static func perform(_ request: Data, bundle: VPhoneBundle, timeout: Int) -> VPhoneGuestOutcome {
        let path = socketPath(for: bundle)
        do {
            let line = try HostControlClient.exchange(socketPath: path, request: request, timeout: TimeInterval(timeout))
            return VPhoneGuestOutcome(response: line)
        } catch let failure as HostControlClient.Failure {
            return .failure("\(bundle.name): \(describe(failure, path: path, timeout: timeout))")
        } catch {
            return .failure("\(bundle.name): \(error)")
        }
    }

    static func describe(_ failure: HostControlClient.Failure, path: String, timeout: Int) -> String {
        func reason(_ code: Int32) -> String { String(cString: strerror(code)) }
        switch failure {
        case let .pathTooLong(bytes, maximum):
            return "socket path is \(bytes) bytes, over the \(maximum)-byte sun_path limit: \(path)"
        case .missing:
            return "no host-control socket at \(path); the VM is not running or was started by a build without host control"
        case .notSocket:
            return "\(path) is not a socket"
        case let .notOwned(uid):
            return "\(path) is owned by uid \(uid), not the current user (uid \(geteuid()))"
        case let .inspectFailed(code):
            return "cannot inspect \(path): \(reason(code))"
        case let .connectFailed(code) where code == ECONNREFUSED:
            return "connect to \(path) refused; no VM process is listening (stale socket)"
        case let .connectFailed(code):
            return "connect to \(path) failed: \(reason(code))"
        case let .writeFailed(code):
            return "sending the request failed: \(reason(code))"
        case let .readFailed(code):
            return "reading the response failed: \(reason(code))"
        case .timedOut:
            return "no complete response within \(timeout) s"
        case let .closedBeforeLine(received):
            return "connection closed before a complete response line (\(received) bytes received)"
        case let .responseTooLarge(limit):
            return "response exceeds \(limit) bytes"
        }
    }
}

// MARK: - Outcome

/// What a guest command writes and its exit status, kept apart from `run()`.
struct VPhoneGuestOutcome: Equatable {
    var stdout: Data?
    var stderr: String?
    var exitCode: Int32

    static func failure(_ reason: String) -> VPhoneGuestOutcome {
        VPhoneGuestOutcome(stdout: nil, stderr: "error: \(reason)", exitCode: 2)
    }

    /// Maps a complete response line (without its LF).
    init(response line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            self = .failure("response is not a JSON object")
            return
        }
        // Only a JSON `true` counts; NSNumber would also bridge 1 to Bool.
        let ok = (object["ok"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        self.init(stdout: line + Data([10]), stderr: nil, exitCode: ok ? 0 : 1)
    }

    init(stdout: Data?, stderr: String?, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    func emit() throws {
        if let stdout { FileHandle.standardOutput.write(stdout) }
        if let stderr { FileHandle.standardError.write(Data((stderr + "\n").utf8)) }
        if exitCode != 0 { throw ExitCode(exitCode) }
    }
}

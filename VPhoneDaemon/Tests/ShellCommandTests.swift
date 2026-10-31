import Darwin
import Foundation

// Only platform routing is stubbed; the production Swift command controller
// and production C executor are compiled unchanged into this harness.
enum GuestAPIError: Error { case invalidRequest(String), operationFailed(String) }
enum GuestAPI {
    static func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else {
            throw GuestAPIError.invalidRequest(key)
        }
        return value
    }
}
enum GuestShellSessionHandler {
    static func resolveProgram(_: String) throws -> String? { "/bin/sh" }
}

@main
struct ShellCommandTests {
    static func main() throws {
        let commands = GuestShellCommands.shared
        var count = 0
        for override: [String: Any] in [
            ["cwd": 123], ["timeout_ms": "100"], ["timeout_ms": true],
            ["timeout_ms": 1.5], ["timeout_ms": 0], ["timeout_ms": 120001],
            ["cmd": "prefix\0suffix"], ["cwd": "/tmp\0suffix"],
        ] {
            var params: [String: Any] = ["request_id": UUID().uuidString, "cmd": "printf executed"]
            params.merge(override) { _, new in new }
            do {
                _ = try commands.execute(params)
                fatalError("invalid parameters reached execution: \(override)")
            } catch GuestAPIError.invalidRequest { count += 1 }
        }
        let identifier = UUID().uuidString
        let params: [String: Any] = ["request_id": identifier, "cmd": "printf '%s' \"$PPID\""]
        let result = try commands.execute(params)
        precondition(result["stdout"] as? String == String(getpid()))
        precondition(result["exit_code"] as? Int == 0)
        count += 1
        do {
            _ = try commands.execute(params)
            fatalError("finished request was replayed")
        } catch GuestAPIError.operationFailed { count += 1 }

        // A completed request's HTTP close must not consume an early-cancel
        // entry and eventually prevent cancellation of a queued command.
        for _ in 0 ..< 140 {
            let id = UUID().uuidString
            _ = try commands.execute(["request_id": id, "cmd": "exit 0"])
            precondition(!commands.cancel(id))
        }
        let cancelled = UUID().uuidString
        precondition(!commands.cancel(cancelled))
        let stopped = try commands.execute(["request_id": cancelled, "cmd": "printf must-not-run"])
        precondition(stopped["cancelled"] as? Bool == true)
        precondition(stopped["stdout"] as? String == "")
        count += 1
        print("\(count) Swift shell controller tests passed")
    }
}

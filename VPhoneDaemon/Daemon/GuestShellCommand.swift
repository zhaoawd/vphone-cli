import Darwin
import Foundation
import VphonedNative

private final class GuestShellCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// One-shot POSIX commands, independent of the interactive terminal route.
final class GuestShellCommands: @unchecked Sendable {
    static let shared = GuestShellCommands()
    private let lock = NSLock()
    private var jobs: [String: GuestShellCancellation] = [:]
    private var cancelledBeforeStart: [String: Date] = [:]
    private var completed: [String: Date] = [:]

    private func trimHistory() {
        completed = completed.filter { $0.value.timeIntervalSinceNow > -180 }
        cancelledBeforeStart = cancelledBeforeStart.filter { $0.value.timeIntervalSinceNow > -180 }
        for history in [true, false] {
            let values = history ? completed : cancelledBeforeStart
            if values.count >= 128, let oldest = values.min(by: { $0.value < $1.value })?.key {
                if history { completed.removeValue(forKey: oldest) }
                else { cancelledBeforeStart.removeValue(forKey: oldest) }
            }
        }
    }

    static var program: String? {
        (try? GuestShellSessionHandler.resolveProgram("sh")) ?? nil
    }

    @discardableResult
    func cancel(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let job = jobs[identifier] { job.cancel(); return true }
        trimHistory()
        if completed[identifier] != nil { return false }
        cancelledBeforeStart[identifier] = Date()
        return false
    }

    func execute(_ params: [String: Any]) throws -> [String: Any] {
        let identifier = try GuestAPI.string(params, "request_id")
        guard UUID(uuidString: identifier) != nil else {
            throw GuestAPIError.invalidRequest("request_id must be a UUID")
        }
        let command = try GuestAPI.string(params, "cmd")
        guard params["cwd"] == nil || params["cwd"] is String else {
            throw GuestAPIError.invalidRequest("cwd must be a string")
        }
        let cwd = params["cwd"] as? String
        guard !command.utf8.contains(0), command.utf8.count <= 128 * 1024,
              cwd == nil || (cwd!.hasPrefix("/") && !cwd!.utf8.contains(0)) else {
            throw GuestAPIError.invalidRequest("cmd/cwd contains an invalid value")
        }
        if let value = params["timeout_ms"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw GuestAPIError.invalidRequest("timeout_ms must be an integer")
            }
        }
        let timeout = (params["timeout_ms"] as? NSNumber)?.doubleValue ?? 30000
        guard timeout.isFinite, timeout.rounded() == timeout, timeout >= 1, timeout <= 120000 else {
            throw GuestAPIError.invalidRequest("timeout_ms must be 1...120000")
        }
        guard let program = Self.program else {
            throw GuestAPIError.operationFailed("POSIX shell is unavailable; install a bootstrap before shell.exec")
        }
        let job = GuestShellCancellation()
        lock.lock()
        trimHistory()
        guard jobs.count < 8, jobs[identifier] == nil, completed[identifier] == nil else {
            lock.unlock()
            throw GuestAPIError.operationFailed("shell.exec is busy or request_id is already active")
        }
        if cancelledBeforeStart.removeValue(forKey: identifier) != nil { job.cancel() }
        jobs[identifier] = job
        lock.unlock()
        defer {
            lock.lock()
            jobs.removeValue(forKey: identifier)
            trimHistory()
            completed[identifier] = Date()
            lock.unlock()
        }
        var result = vp_shell_result()
        let context = Unmanaged.passUnretained(job).toOpaque()
        let check: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { pointer in
            guard let pointer else { return true }
            return Unmanaged<GuestShellCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled()
        }
        let code = vp_shell_execute(program, command, cwd, Int32(timeout), check, context, &result)
        guard code == 0 else { throw GuestAPIError.operationFailed("shell.exec: \(String(cString: strerror(code)))") }
        defer { vp_shell_result_free(&result) }
        let stdout = String(decoding: UnsafeBufferPointer(start: result.out_bytes, count: result.out_length), as: UTF8.self)
        let stderr = String(decoding: UnsafeBufferPointer(start: result.err_bytes, count: result.err_length), as: UTF8.self)
        return ["stdout": stdout, "stderr": stderr, "exit_code": Int(result.exit_code),
                "timed_out": result.timed_out, "cancelled": result.cancelled,
                "stdout_truncated": result.stdout_truncated, "stderr_truncated": result.stderr_truncated,
                "request_id": identifier]
    }
}

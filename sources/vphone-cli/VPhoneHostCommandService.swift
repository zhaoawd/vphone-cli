import Foundation
import VPhoneCore

/// Delivers one result per call. Cancelled operations retain their slot until
/// they actually finish, including dependencies that ignore Task cancellation.
@MainActor
final class VPhoneHostCommandService {
    nonisolated static let defaultTimeoutMilliseconds = 180_000
    typealias Execute = @MainActor (Data) async -> Data
    private let execute: Execute
    private let timeout: Duration
    private let limit: Int
    private var stopped = false
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var replies: [UUID: CheckedContinuation<Data, Never>] = [:]

    init(timeout: Duration = .milliseconds(defaultTimeoutMilliseconds), limit: Int = HostControlIO.maximumConnections,
         execute: @escaping Execute) {
        self.timeout = timeout
        self.limit = limit
        self.execute = execute
    }

    func submit(_ request: Data) async -> Data {
        guard !stopped, !Task.isCancelled else { return failure("command_cancelled") }
        guard jobs.count < limit else { return failure("command_busy") }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                replies[id] = continuation
                jobs[id] = Task {
                    let result = await execute(request)
                    finish(id, result: result)
                }
                timers[id] = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    cancel(id, code: "command_timeout")
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id, code: "command_cancelled") }
        }
    }

    func stop() {
        stopped = true
        for id in Array(jobs.keys) { cancel(id, code: "command_cancelled") }
    }

    private func finish(_ id: UUID, result: Data) {
        jobs.removeValue(forKey: id)
        timers.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)?.resume(returning: result)
    }

    private func cancel(_ id: UUID, code: String) {
        jobs[id]?.cancel()
        timers.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)?.resume(returning: failure(code, mayContinue: true))
    }

    private func failure(_ code: String, mayContinue: Bool = false) -> Data {
        VPhoneHostCommandExecutor.response(ok: false, error: code,
                                          extra: ["code": code, "operation_may_continue": mayContinue])
    }
}

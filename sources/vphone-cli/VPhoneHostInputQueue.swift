import Foundation

// MARK: - Input Queue

/// Runs socket input commands (tap, swipe, key, forwarded input methods) one at
/// a time across all clients. An operation starts only after the previous one
/// returned, so a forwarded `input.*` call cannot interleave with an injected
/// gesture that is still emitting events. A cancelled request that has not
/// started yet does not run; a started one keeps the queue until it returns.
@MainActor
final class VPhoneHostInputQueue {
    private var tail: Task<Void, Never>?

    /// Operations running or waiting, for tests and diagnostics.
    private(set) var pending = 0

    func run<T: Sendable>(cancelled: T, _ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        pending += 1
        let operation = Task { @MainActor () -> T in
            await previous?.value
            defer { self.pending -= 1 }
            if Task.isCancelled { return cancelled }
            return await body()
        }
        tail = Task { _ = await operation.value }
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }
}

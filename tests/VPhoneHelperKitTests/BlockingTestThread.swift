import Foundation

// Synchronous XPC/ACK waits must not occupy Swift's cooperative executor.
func onHelperTestThread<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
    let result: Result<Value, any Error> = await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: Result(catching: body))
        }
    }
    return try result.get()
}

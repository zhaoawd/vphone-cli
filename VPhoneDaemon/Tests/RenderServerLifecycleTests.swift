import Foundation

private final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    let done = DispatchSemaphore(value: 0)
    func restarted() { lock.withLock { count += 1 }; done.signal() }
}

@main enum RenderServerLifecycleTests {
    static func main() {
        let counter = Counter()
        let lifecycle = GuestRenderServerLifecycle { counter.restarted() }
        lifecycle.observe(nil)
        lifecycle.observe("73:100:2")
        lifecycle.observe("73:100:2")
        lifecycle.observe(nil)
        precondition(lifecycle.beginRequest())
        precondition(lifecycle.beginRequest())
        // A reused PID with a different start time is a new renderer too.
        lifecycle.observe("73:200:1")
        precondition(!lifecycle.beginRequest())
        precondition(counter.done.wait(timeout: .now() + 0.6) == .timedOut)
        lifecycle.endRequest()
        precondition(counter.done.wait(timeout: .now() + 0.6) == .timedOut)
        lifecycle.endRequest()
        precondition(counter.done.wait(timeout: .now() + 2) == .success)
        lifecycle.observe("99:300:1")
        precondition(counter.done.wait(timeout: .now() + 0.6) == .timedOut)
        precondition(counter.lock.withLock { counter.count } == 1)
        print("render lifecycle: startup, transient absence, PID reuse, in-flight drain, admission and one restart passed")
    }
}

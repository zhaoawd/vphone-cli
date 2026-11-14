import Darwin
import Foundation

/// CADisplay retains render-server objects by numeric display ID. A new
/// backboardd can reuse that ID with a new UUID. Recreate the worker, and its
/// private-framework clients, after draining requests from the old server.
final class GuestRenderServerLifecycle: @unchecked Sendable {
    static let shared = GuestRenderServerLifecycle(restart: { _exit(75) })
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "vphoned.render-server-lifecycle")
    private let restart: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private var epoch: String?
    private var active = 0
    private var pending = false
    private var scheduled = false

    init(restart: @escaping @Sendable () -> Void) { self.restart = restart }

    func start(readEpoch: @escaping @Sendable () -> String?) {
        guard timer == nil else { return }
        observe(readEpoch())
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [self] in observe(readEpoch()) }
        self.timer = timer
        timer.resume()
    }

    func beginRequest() -> Bool {
        lock.withLock {
            guard !pending else { return false }
            active += 1
            return true
        }
    }

    func endRequest() {
        lock.withLock {
            precondition(active > 0)
            active -= 1
            scheduleIfDrained()
        }
    }

    func observe(_ value: String?) {
        guard let value else { return }
        lock.withLock {
            if let epoch, epoch != value { pending = true }
            epoch = value
            scheduleIfDrained()
        }
    }

    /// Called under lock. New requests have already been refused, while the
    /// response from the last old request gets a turn to flush before exit.
    private func scheduleIfDrained() {
        guard pending, active == 0, !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [restart] in
            NSLog("vphoned: render server changed; recreating the API worker")
            restart()
        }
    }
}

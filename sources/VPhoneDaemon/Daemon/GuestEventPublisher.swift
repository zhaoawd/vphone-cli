import Foundation
import IcliKit

/// Publishes the state a UI needs without requiring it to poll over HTTP.
/// State polling runs separately so a stalled powerd read cannot block commands.
final class GuestEventPublisher: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "vphoned.api.state", qos: .utility)
    private static let interval: DispatchTimeInterval = .seconds(3)
    private let hub: APIEventHub
    private let timer: DispatchSourceTimer
    /// Accessed only on queue.
    private var previous: Data?
    private var polling = false

    init(hub: APIEventHub) {
        self.hub = hub
        timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.publishIfChanged() }
        timer.resume()
        hub.onSubscribedChange = { [weak self] subscribed in
            guard let self else { return }
            Self.queue.async { self.updatePolling(resetSnapshot: subscribed) }
        }
        Self.queue.async { [weak self] in self?.updatePolling() }
    }

    deinit { timer.cancel() }

    private func updatePolling(resetSnapshot: Bool = false) {
        // Re-read membership because callbacks from different channels may
        // arrive out of order. A new subscription must get a fresh snapshot
        // even if the queue has not processed the preceding disconnect yet.
        let subscribed = hub.hasSubscribers
        if subscribed && resetSnapshot { previous = nil }
        guard subscribed != polling || (subscribed && resetSnapshot) else { return }
        polling = subscribed
        if subscribed {
            timer.schedule(deadline: .now(), repeating: Self.interval)
        } else {
            previous = nil
            timer.schedule(deadline: .distantFuture)
        }
    }

    private func publishIfChanged() {
        guard hub.hasSubscribers else {
            previous = nil
            return
        }
        let state: [String: Any] = [
            "screen": screenInfo(),
            "frontmost_app": frontmostApp(),
            "low_power_mode": (try? lowPowerMode()) ?? [:],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              data != previous
        else { return }
        previous = data
        hub.broadcast(name: "device.state", data: state)
    }
}

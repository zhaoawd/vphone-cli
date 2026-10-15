// Only scheduling, platform reads and NIO transport are stand-ins. APIEventHub
// and GuestEventPublisher are compiled from their production source files.
enum DispatchTime: Equatable {
    case immediate, distantFuture
    static func now() -> Self { .immediate }
}

enum DispatchTimeInterval: Equatable { case seconds(Int) }

final class DispatchQueue: @unchecked Sendable {
    enum QoS { case utility }
    private var pending: [@Sendable () -> Void] = []
    init(label: String, qos: QoS) {}
    func async(execute: @escaping @Sendable () -> Void) { pending.append(execute) }
    func drain(reversed: Bool = false) {
        while !pending.isEmpty {
            let operation = reversed ? pending.removeLast() : pending.removeFirst()
            operation()
        }
    }
}

final class ProbeTimer {
    let queue: DispatchQueue
    var deadline: DispatchTime?
    var interval: DispatchTimeInterval?
    var schedules = 0
    var cancelled = false
    private var resumed = false
    private var handler: (() -> Void)?
    init(queue: DispatchQueue) { self.queue = queue }
    func schedule(deadline: DispatchTime, repeating: DispatchTimeInterval? = nil) {
        self.deadline = deadline
        interval = repeating
        schedules += 1
    }
    func setEventHandler(handler: @escaping () -> Void) { self.handler = handler }
    func resume() { resumed = true }
    func cancel() { cancelled = true }
    // A timer event may already be queued when its schedule is disabled.
    func firePending() {
        check(resumed && !cancelled, "invalid timer lifecycle")
        handler?()
    }
}

typealias DispatchSourceTimer = ProbeTimer
enum DispatchSource {
    nonisolated(unsafe) static var created: ProbeTimer?
    static func makeTimerSource(queue: DispatchQueue) -> ProbeTimer {
        let timer = ProbeTimer(queue: queue)
        created = timer
        return timer
    }
}

struct APIReply {
    let data: Data
    static func json(_ value: [String: Any]) -> Self {
        Self(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
}

struct Buffer {
    var data = Data()
    mutating func writeBytes(_ bytes: Data) { data.append(bytes) }
}
struct Allocator { func buffer(capacity: Int) -> Buffer { Buffer() } }
struct WebSocketFrame {
    enum Opcode { case text }
    let fin: Bool
    let opcode: Opcode
    let data: Buffer
}
struct EventLoop { func execute(_ body: @Sendable () -> Void) { body() } }
final class Channel: @unchecked Sendable {
    let eventLoop = EventLoop()
    let allocator = Allocator()
    var isActive = true
    var messages: [Data] = []
    func writeAndFlush(_ frame: WebSocketFrame, promise: Void?) { messages.append(frame.data.data) }
}

enum Reads {
    nonisolated(unsafe) static var screen = 0
    nonisolated(unsafe) static var frontmost = 0
    nonisolated(unsafe) static var power = 0
    nonisolated(unsafe) static var value = 0
}
func screenInfo() -> [String: Any] { Reads.screen += 1; return ["value": Reads.value] }
func frontmostApp() -> [String: Any] { Reads.frontmost += 1; return ["bundle_id": "fixture"] }
func lowPowerMode() throws -> [String: Any] { Reads.power += 1; return ["enabled": false] }
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print(message); exit(1) }
}

final class MembershipObservations: @unchecked Sendable { var values: [Bool] = [] }
let observedHub = APIEventHub()
let observations = MembershipObservations()
observedHub.onSubscribedChange = { subscribed in
    // Re-entering the hub detects notifications accidentally sent under its lock.
    check(observedHub.hasSubscribers == subscribed, "membership notification disagreed with the hub")
    observations.values.append(subscribed)
}
let observedChannel = Channel(), nonmember = Channel()
observedHub.add(observedChannel)
observedHub.add(observedChannel)
observedHub.remove(nonmember)
observedHub.remove(observedChannel)
observedHub.remove(observedChannel)
check(observations.values == [true, false], "duplicate add/remove produced a boundary notification")

let hub = APIEventHub()
var publisher: GuestEventPublisher? = GuestEventPublisher(hub: hub)
let timer = DispatchSource.created!
timer.queue.drain()
check(timer.deadline == .distantFuture && timer.interval == nil, "idle publisher armed a repeating timer")
timer.firePending()
check(Reads.screen == 0 && Reads.frontmost == 0 && Reads.power == 0, "idle publisher queried device state")

let first = Channel(), second = Channel(), unknown = Channel()
hub.add(first)
timer.queue.drain()
check(timer.deadline == .immediate && timer.interval == .seconds(3), "first subscriber did not start immediate polling")
timer.firePending()
check(first.messages.count == 1, "first subscriber missed its initial state")
timer.firePending()
check(first.messages.count == 1, "unchanged state was broadcast twice")
Reads.value = 1
timer.firePending()
check(first.messages.count == 2, "changed state was not broadcast")
let event = try JSONSerialization.jsonObject(with: first.messages.last!) as! [String: Any]
check(event["type"] as? String == "event" && event["event"] as? String == "device.state", "event envelope changed")

let schedules = timer.schedules
hub.add(first)
hub.add(second)
hub.remove(unknown)
hub.remove(first)
timer.queue.drain()
check(timer.schedules == schedules && timer.interval == .seconds(3), "non-boundary membership changed polling")
Reads.value = 2
timer.firePending()
check(first.messages.count == 2 && second.messages.count == 1, "broadcast recipients were not current subscribers")
hub.remove(second)
timer.queue.drain()
check(timer.deadline == .distantFuture && timer.interval == nil, "last subscriber left the timer armed")
let reads = Reads.screen
timer.firePending()
check(Reads.screen == reads, "queued idle event queried state")

hub.add(first)
timer.queue.drain()
timer.firePending()
check(first.messages.count == 3, "reconnect missed an unchanged initial state")
hub.remove(first)
hub.add(second)
timer.queue.drain()
timer.firePending()
check(second.messages.count == 2, "rapid reconnect reused the previous subscriber's snapshot")

hub.remove(second)
hub.add(first)
hub.remove(first)
timer.queue.drain(reversed: true)
check(timer.deadline == .distantFuture && timer.interval == nil, "out-of-order callbacks armed an idle publisher")
let finalReads = Reads.screen
timer.firePending()
check(Reads.screen == finalReads, "stale callback queried state without subscribers")
check(Reads.screen == Reads.frontmost && Reads.frontmost == Reads.power, "state read groups diverged")
publisher = nil
check(timer.cancelled, "publisher did not cancel its timer on release")

let existingHub = APIEventHub(), existingChannel = Channel()
existingHub.add(existingChannel)
var latePublisher: GuestEventPublisher? = GuestEventPublisher(hub: existingHub)
let lateTimer = DispatchSource.created!
lateTimer.queue.drain()
check(lateTimer.deadline == .immediate && lateTimer.interval == .seconds(3), "existing subscriber was missed during initialization")
lateTimer.firePending()
check(existingChannel.messages.count == 1, "existing subscriber missed initial state")
latePublisher = nil
check(lateTimer.cancelled, "late publisher did not release its timer")

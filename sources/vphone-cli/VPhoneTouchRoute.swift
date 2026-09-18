/// A gesture stays on its original transport and guest connection generation.
///
/// State is kept per gesture, not in a single slot: two gestures can be in
/// flight at once (a user click while an injected gesture is still emitting its
/// queued events), and neither may overwrite or end the other's routing.
struct VPhoneTouchRoute {
    enum Destination: Equatable {
        case native
        case guest(UInt64)
        case discard
    }

    /// Which gesture a touch phase belongs to. Real user mouse events all share
    /// `.user` (the window delivers them one gesture at a time); each injected
    /// gesture carries its own id.
    enum GestureID: Hashable {
        case user
        case injected(Int)
    }

    /// Only gestures with a live destination are kept. A gesture that ends, or
    /// whose destination becomes `.discard`, is removed, so the map holds at
    /// most the gestures currently in flight.
    private var active: [GestureID: Destination] = [:]

    mutating func destination(gesture: GestureID, phase: Int, guestSession: UInt64?) -> Destination {
        var current: Destination
        if phase == 0 {
            current = guestSession.map(Destination.guest) ?? .native
        } else {
            current = active[gesture] ?? .discard
        }
        if case let .guest(session) = current, guestSession != session {
            current = .discard
        }
        if phase == 3 || current == .discard {
            active[gesture] = nil
        } else {
            active[gesture] = current
        }
        return current
    }

    /// Drop a gesture's routing state. Called when an injected gesture has
    /// emitted its last event, so an interrupted gesture cannot leak an entry.
    mutating func endGesture(_ gesture: GestureID) {
        active[gesture] = nil
    }

    /// Gestures currently holding routing state. For tests and diagnostics.
    var activeGestureCount: Int { active.count }
}

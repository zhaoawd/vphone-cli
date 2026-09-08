/// A gesture stays on its original transport and guest connection generation.
struct VPhoneTouchRoute {
    enum Destination: Equatable {
        case native
        case guest(UInt64)
        case discard
    }

    private var active: Destination = .discard

    mutating func destination(phase: Int, guestSession: UInt64?) -> Destination {
        if phase == 0 {
            active = guestSession.map(Destination.guest) ?? .native
        }
        if case let .guest(session) = active, guestSession != session {
            active = .discard
        }
        let result = active
        if phase == 3 { active = .discard }
        return result
    }
}

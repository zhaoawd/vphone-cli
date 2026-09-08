import Testing
@testable import vphone_cli

struct TouchRouteTests {
    @Test func guestGestureDoesNotCrossSessionsOrFallBack() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(phase: 0, guestSession: 7) == .guest(7))
        #expect(route.destination(phase: 1, guestSession: nil) == .discard)
        #expect(route.destination(phase: 1, guestSession: 8) == .discard)
        #expect(route.destination(phase: 3, guestSession: 8) == .discard)
        #expect(route.destination(phase: 0, guestSession: 8) == .guest(8))
        #expect(route.destination(phase: 3, guestSession: 8) == .guest(8))
    }

    @Test func nativeGestureStaysNativeWhenGuestConnects() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(phase: 0, guestSession: nil) == .native)
        #expect(route.destination(phase: 1, guestSession: 1) == .native)
        #expect(route.destination(phase: 3, guestSession: 1) == .native)
        #expect(route.destination(phase: 1, guestSession: 1) == .discard)
    }
}

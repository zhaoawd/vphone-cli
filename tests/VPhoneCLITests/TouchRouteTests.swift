import AppKit
import Testing
@testable import vphone_cli

struct TouchRouteTests {
    @Test func orphanMoveAndReleaseNeverStartAGesture() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(gesture: .user, phase: 1, guestSession: nil) == .discard)
        #expect(route.destination(gesture: .user, phase: 3, guestSession: nil) == .discard)
        #expect(route.destination(gesture: .user, phase: 1, guestSession: 7) == .discard)
        #expect(route.destination(gesture: .user, phase: 3, guestSession: 7) == .discard)
    }

    @Test func reconnectWithoutAnObservedDisconnectedEventDiscardsOldGesture() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(gesture: .user, phase: 0, guestSession: 7) == .guest(7))
        #expect(route.destination(gesture: .user, phase: 1, guestSession: 8) == .discard)
        #expect(route.destination(gesture: .user, phase: 3, guestSession: 8) == .discard)
        #expect(route.destination(gesture: .user, phase: 0, guestSession: 8) == .guest(8))
        #expect(route.destination(gesture: .user, phase: 1, guestSession: 8) == .guest(8))
        #expect(route.destination(gesture: .user, phase: 3, guestSession: 8) == .guest(8))
    }

    @Test func disconnectedNewGestureUsesNativeAfterGuestGestureEnds() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(gesture: .user, phase: 0, guestSession: 7) == .guest(7))
        #expect(route.destination(gesture: .user, phase: 3, guestSession: nil) == .discard)
        #expect(route.destination(gesture: .user, phase: 0, guestSession: nil) == .native)
        #expect(route.destination(gesture: .user, phase: 1, guestSession: nil) == .native)
        #expect(route.destination(gesture: .user, phase: 3, guestSession: nil) == .native)
    }

    @Test func guestGestureDoesNotCrossSessionsOrFallBack() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(gesture: .user, phase: 0, guestSession: 7) == .guest(7))
        #expect(route.destination(gesture: .user, phase: 1, guestSession: nil) == .discard)
        #expect(route.destination(gesture: .user, phase: 1, guestSession: 8) == .discard)
        #expect(route.destination(gesture: .user, phase: 3, guestSession: 8) == .discard)
        #expect(route.destination(gesture: .user, phase: 0, guestSession: 8) == .guest(8))
        #expect(route.destination(gesture: .user, phase: 3, guestSession: 8) == .guest(8))
    }

    @Test func nativeGestureStaysNativeWhenGuestConnects() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(gesture: .user, phase: 0, guestSession: nil) == .native)
        #expect(route.destination(gesture: .user, phase: 1, guestSession: 1) == .native)
        #expect(route.destination(gesture: .user, phase: 3, guestSession: 1) == .native)
        #expect(route.destination(gesture: .user, phase: 1, guestSession: 1) == .discard)
    }

    // MARK: - Interleaved Gestures

    @Test func interleavedGesturesKeepTheirOwnDestination() {
        var route = VPhoneTouchRoute()
        // A starts while the guest is connected, B starts before A ends.
        #expect(route.destination(gesture: .injected(1), phase: 0, guestSession: 7) == .guest(7))
        #expect(route.destination(gesture: .injected(2), phase: 0, guestSession: 7) == .guest(7))
        #expect(route.destination(gesture: .injected(1), phase: 1, guestSession: 7) == .guest(7))
        #expect(route.destination(gesture: .injected(2), phase: 1, guestSession: 7) == .guest(7))
    }

    @Test func endingOneGestureDoesNotEndTheOther() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(gesture: .injected(1), phase: 0, guestSession: 7) == .guest(7))
        #expect(route.destination(gesture: .injected(2), phase: 0, guestSession: 7) == .guest(7))
        // A's release must not strand B's remaining phases.
        #expect(route.destination(gesture: .injected(1), phase: 3, guestSession: 7) == .guest(7))
        #expect(route.destination(gesture: .injected(2), phase: 1, guestSession: 7) == .guest(7))
        #expect(route.destination(gesture: .injected(2), phase: 3, guestSession: 7) == .guest(7))
        // Both gestures ended; nothing is left behind.
        #expect(route.activeGestureCount == 0)
    }

    @Test func userGestureIsNotDisturbedByAnInjectedGesture() {
        var route = VPhoneTouchRoute()
        // A real click starts while the guest is absent, so it routes natively.
        #expect(route.destination(gesture: .user, phase: 0, guestSession: nil) == .native)
        // An injected gesture on a connected guest runs concurrently.
        #expect(route.destination(gesture: .injected(1), phase: 0, guestSession: 4) == .guest(4))
        #expect(route.destination(gesture: .injected(1), phase: 3, guestSession: 4) == .guest(4))
        #expect(route.destination(gesture: .user, phase: 1, guestSession: 4) == .native)
        #expect(route.destination(gesture: .user, phase: 3, guestSession: 4) == .native)
        #expect(route.activeGestureCount == 0)
    }

    @Test func discardedGestureLeavesNoEntry() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(gesture: .injected(1), phase: 0, guestSession: 7) == .guest(7))
        // A session change discards the gesture and drops its entry.
        #expect(route.destination(gesture: .injected(1), phase: 1, guestSession: 8) == .discard)
        #expect(route.activeGestureCount == 0)
        #expect(route.destination(gesture: .injected(1), phase: 3, guestSession: 8) == .discard)
    }

    @Test func endGestureClearsAnUnreleasedGesture() {
        var route = VPhoneTouchRoute()
        #expect(route.destination(gesture: .injected(1), phase: 0, guestSession: 7) == .guest(7))
        #expect(route.activeGestureCount == 1)
        route.endGesture(.injected(1))
        #expect(route.activeGestureCount == 0)
        #expect(route.destination(gesture: .injected(1), phase: 1, guestSession: 7) == .discard)
    }
}

// MARK: - Gesture Queue Bound

@MainActor
struct GestureQueueTests {
    /// The queue holds one emitting gesture plus `maxPendingGestures` waiting
    /// ones; the next injection is rejected rather than silently dropped.
    @Test func gestureQueueRejectsInjectionWhenFull() {
        let view = VPhoneVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
        let capacity = VPhoneVirtualMachineView.maxPendingGestures + 1
        for _ in 0 ..< capacity {
            #expect(view.injectTap(pixelX: 10, pixelY: 20, screenWidth: 390, screenHeight: 844))
        }
        #expect(view.pendingGestureCount == capacity)
        #expect(view.injectTap(pixelX: 10, pixelY: 20, screenWidth: 390, screenHeight: 844) == false)
        #expect(view.injectSwipe(fromX: 10, fromY: 20, toX: 10, toY: 200,
                                 screenWidth: 390, screenHeight: 844, durationMs: 300) == false)
        #expect(view.pendingGestureCount == capacity)
    }
}

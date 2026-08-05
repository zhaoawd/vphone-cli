import XCTest
@testable import vphone_cli

@MainActor
private final class FakeSystemLocationGuestAdapter: SystemLocationGuestAdapter {
    struct Delivery: Equatable {
        let fix: SystemLocationFix
        let generation: String
        let sequence: Int
    }

    var deliveries: [Delivery] = []
    var clears: [String] = []
    var failuresRemaining = 0

    func deliver(
        _ fix: SystemLocationFix,
        generation: String,
        deliverySequence: Int
    ) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw SystemLocationControllerError(
                code: "location_delivery_timeout", message: "test timeout")
        }
        deliveries.append(Delivery(
            fix: fix, generation: generation, sequence: deliverySequence))
    }

    func clear(generation: String) async throws {
        clears.append(generation)
    }
}

@MainActor
final class SystemLocationControllerTests: XCTestCase {
    private func fix(_ sequence: Int, latitude: Double = 31.2) -> SystemLocationFix {
        SystemLocationFix(
            producerSequence: sequence,
            latitude: latitude, longitude: 118.8, altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 8,
            speed: 10, course: 90, timestamp: 1_700_000_000)
    }

    func testStreamAcceptsStrictSequenceAndCachesIdenticalRetry() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try controller.startStream(owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)

        _ = try await controller.push(generation: generation, fix: fix(0))
        _ = try await controller.push(generation: generation, fix: fix(0))
        _ = try await controller.push(generation: generation, fix: fix(1, latitude: 31.21))

        XCTAssertEqual(guest.deliveries.map(\.sequence), [0, 1])
        let status = controller.snapshot()
        let applied = try XCTUnwrap(status["applied"] as? [String: Any])
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 1)
        XCTAssertEqual(applied["last_delivery_sequence"] as? Int, 1)
    }

    func testSequenceCommitsOnlyAfterGuestAck() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        guest.failuresRemaining = 1
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try controller.startStream(owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)

        do {
            _ = try await controller.push(generation: generation, fix: fix(0))
            XCTFail("first delivery should fail")
        } catch let error as SystemLocationControllerError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        _ = try await controller.push(generation: generation, fix: fix(0))

        XCTAssertEqual(guest.deliveries.count, 1)
        XCTAssertEqual(guest.deliveries[0].sequence, 0)
    }

    func testOldGenerationCannotPushOrStopReplacement() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let first = try controller.startStream(owner: "route-1", watchdogSeconds: 60)
        let oldGeneration = try XCTUnwrap(first["generation"] as? String)
        let second = try controller.startStream(
            owner: "route-2", watchdogSeconds: 60, replace: true)
        let currentGeneration = try XCTUnwrap(second["generation"] as? String)

        for operation in [
            { try await controller.push(generation: oldGeneration, fix: self.fix(0)) },
            { try await controller.stop(generation: oldGeneration) },
        ] {
            do {
                _ = try await operation()
                XCTFail("old generation should be rejected")
            } catch let error as SystemLocationControllerError {
                XCTAssertEqual(error.code, "location_generation_conflict")
            }
        }
        XCTAssertEqual(controller.generation, currentGeneration)
        XCTAssertTrue(guest.clears.isEmpty)
    }

    func testPauseUsesIndependentDeliverySequence() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try controller.startStream(owner: "route-1", watchdogSeconds: 0.01)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        let paused = try await controller.setPaused(true, generation: generation)

        try await Task.sleep(for: .milliseconds(35))

        XCTAssertGreaterThanOrEqual(guest.deliveries.count, 3)
        XCTAssertEqual(guest.deliveries[0].sequence, 0)
        XCTAssertTrue(guest.deliveries.dropFirst().allSatisfy { $0.fix.speed == 0 })
        XCTAssertEqual(paused["state"] as? String, "paused")
    }

    func testStopClearsOnlyOwnedGeneration() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try controller.startStream(owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let stopped = try await controller.stop(generation: generation)

        XCTAssertEqual(guest.clears, [generation])
        XCTAssertEqual(stopped["state"] as? String, "off")
        XCTAssertNil(controller.generation)
    }

    func testOtherOwnerNeedsExplicitReplace() throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        _ = try controller.startStream(owner: "route-1", watchdogSeconds: 60)

        XCTAssertThrowsError(
            try controller.startStream(owner: "route-2", watchdogSeconds: 60)
        ) { error in
            XCTAssertEqual(
                (error as? SystemLocationControllerError)?.code,
                "location_owner_conflict")
        }
        XCTAssertNoThrow(
            try controller.startStream(
                owner: "route-2", watchdogSeconds: 60, replace: true))
    }

    func testWatchdogHoldsLastAcceptedCoordinate() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try controller.startStream(owner: "route-1", watchdogSeconds: 0.01)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertGreaterThanOrEqual(guest.deliveries.count, 2)
        XCTAssertEqual(guest.deliveries[0].fix.speed, 10)
        XCTAssertEqual(guest.deliveries[1].fix.speed, 0)
        XCTAssertEqual(guest.deliveries[0].fix.latitude, guest.deliveries[1].fix.latitude)
        XCTAssertEqual(guest.deliveries.map(\.sequence).prefix(2), [0, 1])
    }

    func testReconnectReappliesLastAckWithNewDeliverySequence() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try controller.startStream(owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))

        await controller.reapplyAfterReconnect()

        XCTAssertEqual(guest.deliveries.map(\.sequence), [0, 1])
        XCTAssertEqual(guest.deliveries[0].fix, guest.deliveries[1].fix)
        XCTAssertEqual(controller.generation, generation)
    }

    func testFixedSourceRefreshesUntilStopped() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.setFixed(
            owner: "dashboard", fix: fix(0), heartbeatSeconds: 0.01)
        let generation = try XCTUnwrap(started["generation"] as? String)

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThanOrEqual(guest.deliveries.count, 2)
        XCTAssertEqual(guest.deliveries.map(\.sequence), Array(0..<guest.deliveries.count))
        _ = try await controller.stop(generation: generation)
    }
}

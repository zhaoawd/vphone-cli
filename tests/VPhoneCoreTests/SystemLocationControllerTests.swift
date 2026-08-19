import XCTest
@testable import VPhoneCore

@MainActor
private final class FakeSystemLocationGuestAdapter: VPhoneSystemLocationGuestAdapter {
    struct Delivery: Equatable {
        let fix: VPhoneSystemLocationFix
        let generation: String
        let sequence: Int
    }

    var activations: [String] = []
    var deliveries: [Delivery] = []
    var clears: [String?] = []
    var failuresRemaining = 0

    func activate(generation: String) async throws {
        activations.append(generation)
    }

    func deliver(
        _ fix: VPhoneSystemLocationFix,
        generation: String,
        deliverySequence: Int
    ) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw VPhoneSystemLocationError(
                code: "location_delivery_timeout", message: "test timeout")
        }
        deliveries.append(Delivery(
            fix: fix, generation: generation, sequence: deliverySequence))
    }

    func clear(generation: String?) async throws {
        clears.append(generation)
    }
}

@MainActor
final class SystemLocationControllerTests: XCTestCase {
    private func fix(_ sequence: Int, latitude: Double = 31.2) -> VPhoneSystemLocationFix {
        VPhoneSystemLocationFix(
            producerSequence: sequence,
            latitude: latitude, longitude: 118.8, altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 8,
            speed: 10, course: 90, timestamp: 1_700_000_000)
    }

    func testStreamAcceptsStrictSequenceAndCachesIdenticalRetry() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
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
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)

        do {
            _ = try await controller.push(generation: generation, fix: fix(0))
            XCTFail("first delivery should fail")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        _ = try await controller.push(generation: generation, fix: fix(0))

        XCTAssertEqual(guest.deliveries.count, 1)
        XCTAssertEqual(guest.deliveries[0].sequence, 0)
    }

    func testOldGenerationCannotPushOrStopReplacement() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let first = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let oldGeneration = try XCTUnwrap(first["generation"] as? String)
        let second = try await controller.startStream(
            owner: "route-2", watchdogSeconds: 60, replace: true)
        let currentGeneration = try XCTUnwrap(second["generation"] as? String)

        for operation in [
            { try await controller.push(generation: oldGeneration, fix: self.fix(0)) },
            { try await controller.stop(generation: oldGeneration) },
        ] {
            do {
                _ = try await operation()
                XCTFail("old generation should be rejected")
            } catch let error as VPhoneSystemLocationError {
                XCTAssertEqual(error.code, "location_generation_conflict")
            }
        }
        XCTAssertEqual(controller.generation, currentGeneration)
        XCTAssertTrue(guest.clears.isEmpty)
    }

    func testPauseUsesIndependentDeliverySequence() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 0.01)
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
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let stopped = try await controller.stop(generation: generation)

        XCTAssertEqual(guest.clears, [generation])
        XCTAssertEqual(stopped["state"] as? String, "off")
        XCTAssertNil(controller.generation)
    }

    func testOtherOwnerNeedsExplicitReplace() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        _ = try await controller.startStream(owner: "route-1", watchdogSeconds: 60)

        do {
            _ = try await controller.startStream(
                owner: "route-2", watchdogSeconds: 60)
            XCTFail("other owner should require replace")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_owner_conflict")
        }
        _ = try await controller.startStream(
            owner: "route-2", watchdogSeconds: 60, replace: true)
    }

    func testWatchdogHoldsLastAcceptedCoordinate() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 0.01)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertGreaterThanOrEqual(guest.deliveries.count, 2)
        XCTAssertEqual(guest.deliveries[0].fix.speed, 10)
        XCTAssertEqual(guest.deliveries[1].fix.speed, 0)
        XCTAssertEqual(guest.deliveries[0].fix.latitude, guest.deliveries[1].fix.latitude)
        XCTAssertEqual(guest.deliveries.map(\.sequence).prefix(2), [0, 1])
        XCTAssertEqual(controller.snapshot()["state"] as? String, "holding")
    }

    func testReconnectReappliesLastAckWithNewDeliverySequence() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))

        await controller.reapplyAfterReconnect()

        XCTAssertEqual(guest.activations, [generation, generation])
        XCTAssertEqual(guest.deliveries.map(\.sequence), [0, 1])
        XCTAssertEqual(
            guest.deliveries[0].fix.producerSequence,
            guest.deliveries[1].fix.producerSequence)
        XCTAssertEqual(
            guest.deliveries[0].fix.latitude,
            guest.deliveries[1].fix.latitude)
        XCTAssertGreaterThan(
            guest.deliveries[1].fix.timestamp,
            guest.deliveries[0].fix.timestamp)
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
        XCTAssertTrue(guest.deliveries.allSatisfy { $0.fix.timestamp > 1_700_000_000 })
        _ = try await controller.stop(generation: generation)
    }

    func testWatchdogCanStopOwnedStream() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1",
            watchdogSeconds: 0.01,
            onTimeout: "stop")
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertNil(controller.generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "off")
        XCTAssertEqual(guest.clears, [generation])
    }

    func testPersistedFixedSourceRestoresWithNewGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VPhoneSystemLocationStateStore(url: stateURL)

        do {
            let guest = FakeSystemLocationGuestAdapter()
            let controller = VPhoneSystemLocationController(
                adapter: guest,
                stateStore: store)
            let snapshot = try await controller.setFixed(
                owner: "dashboard",
                fix: fix(0),
                heartbeatSeconds: 60,
                persist: true)
            let desired = try XCTUnwrap(snapshot["desired"] as? [String: Any])
            XCTAssertEqual(desired["persistent"] as? Bool, true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        }

        let restoredGuest = FakeSystemLocationGuestAdapter()
        let restored = VPhoneSystemLocationController(
            adapter: restoredGuest,
            stateStore: store)
        let before = restored.snapshot()
        let oldGeneration = try XCTUnwrap(before["generation"] as? String)
        XCTAssertEqual(before["state"] as? String, "applying")
        await restored.reapplyAfterReconnect()

        XCTAssertEqual(restoredGuest.activations, [oldGeneration])
        XCTAssertEqual(restoredGuest.deliveries.count, 1)
        XCTAssertEqual(restored.snapshot()["state"] as? String, "running")

        restored.relinquishForGUI()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testInvalidTimeoutModeFailsBeforeGuestActivation() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)

        do {
            _ = try await controller.startStream(
                owner: "route-1",
                watchdogSeconds: 3,
                onTimeout: "continue")
            XCTFail("invalid timeout action should fail")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "invalid_location_source")
        }
        XCTAssertTrue(guest.activations.isEmpty)
    }

    func testFixedSourceRequiresZeroSequenceAndConfiguredPersistence() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)

        do {
            _ = try await controller.setFixed(
                owner: "dashboard",
                fix: fix(1),
                heartbeatSeconds: 1)
            XCTFail("fixed source should require sequence zero")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_sequence_conflict")
        }
        do {
            _ = try await controller.setFixed(
                owner: "dashboard",
                fix: fix(0),
                heartbeatSeconds: 1,
                persist: true)
            XCTFail("persistence should require a state store")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_persistence_unavailable")
        }
        XCTAssertTrue(guest.activations.isEmpty)
    }
}

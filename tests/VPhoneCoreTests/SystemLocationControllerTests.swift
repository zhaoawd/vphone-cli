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
    var deliveryAttempts: [Delivery] = []
    var clears: [String?] = []
    var events: [String] = []
    var availabilityChecks = 0
    var availabilityError: VPhoneSystemLocationError?
    var activationError: VPhoneSystemLocationError?
    var residualLocationActive = false
    private(set) var currentFix: VPhoneSystemLocationFix?
    var applyThenFailNextDelivery = false
    var applyThenFailNextClear = false
    var applyThenFailNextClearError: VPhoneSystemLocationError?
    var clearError: VPhoneSystemLocationError?
    var failuresRemaining = 0
    var suspendNextActivation = false
    var suspendNextClear = false
    var suspendNextDelivery = false
    private var suspendedActivation: CheckedContinuation<Void, Never>?
    private var suspendedClear: CheckedContinuation<Void, Never>?
    private var suspendedDelivery: CheckedContinuation<Void, Never>?
    private var activationStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var deliveryStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var activationIsSuspended = false
    private var clearIsSuspended = false
    private var deliveryIsSuspended = false
    private var guestLastDelivery: Delivery?
    private var guestGeneration: String?
    private var lastClearedGeneration: String?

    func requireOwnedLocationCapability() throws {
        availabilityChecks += 1
        if let availabilityError { throw availabilityError }
    }

    func activate(generation: String) async throws {
        if let activationError { throw activationError }
        activations.append(generation)
        events.append("activate:\(generation)")
        if suspendNextActivation {
            suspendNextActivation = false
            activationIsSuspended = true
            let waiters = activationStartedWaiters
            activationStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { suspendedActivation = $0 }
            activationIsSuspended = false
        }
        residualLocationActive = false
        currentFix = nil
        guestLastDelivery = nil
        guestGeneration = generation
        lastClearedGeneration = nil
    }

    func deliver(
        _ fix: VPhoneSystemLocationFix,
        generation: String,
        deliverySequence: Int
    ) async throws {
        if suspendNextDelivery {
            suspendNextDelivery = false
            deliveryIsSuspended = true
            let waiters = deliveryStartedWaiters
            deliveryStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { suspendedDelivery = $0 }
            deliveryIsSuspended = false
        }
        let delivery = Delivery(
            fix: fix,
            generation: generation,
            sequence: deliverySequence)
        deliveryAttempts.append(delivery)
        events.append("deliver:\(generation):\(deliverySequence)")
        guard guestGeneration == generation else {
            throw VPhoneSystemLocationError(
                code: "location_generation_conflict",
                message: "generation does not own guest location",
                definitiveGuestRejection: true)
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw VPhoneSystemLocationError(
                code: "location_delivery_timeout", message: "test timeout")
        }
        if applyThenFailNextDelivery {
            applyThenFailNextDelivery = false
            deliveries.append(delivery)
            currentFix = fix
            guestLastDelivery = delivery
            throw VPhoneSystemLocationError(
                code: "location_delivery_timeout", message: "test lost ACK")
        }
        if let applied = guestLastDelivery,
           applied.generation == generation,
           applied.sequence == deliverySequence {
            guard applied == delivery else {
                throw VPhoneSystemLocationError(
                    code: "location_sequence_conflict",
                    message: "sequence reused with a different frame",
                    definitiveGuestRejection: true)
            }
            return
        }
        if let applied = guestLastDelivery,
           applied.generation == generation,
           deliverySequence != applied.sequence + 1 {
            throw VPhoneSystemLocationError(
                code: "location_sequence_conflict",
                message: "delivery sequence is not contiguous",
                definitiveGuestRejection: true)
        }
        deliveries.append(delivery)
        currentFix = fix
        guestLastDelivery = delivery
    }

    func clear(generation: String?) async throws {
        clears.append(generation)
        events.append("clear:\(generation ?? "legacy")")
        if suspendNextClear {
            suspendNextClear = false
            clearIsSuspended = true
            let waiters = clearStartedWaiters
            clearStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { suspendedClear = $0 }
            clearIsSuspended = false
        }
        if let generation {
            if guestGeneration == nil, lastClearedGeneration == generation {
                return
            }
            guard guestGeneration == generation else {
                throw VPhoneSystemLocationError(
                    code: "location_generation_conflict",
                    message: "generation does not own guest location",
                    definitiveGuestRejection: true)
            }
        }
        if let clearError { throw clearError }
        residualLocationActive = false
        currentFix = nil
        guestLastDelivery = nil
        lastClearedGeneration = generation
        guestGeneration = nil
        if let error = applyThenFailNextClearError {
            applyThenFailNextClearError = nil
            throw error
        }
        if applyThenFailNextClear {
            applyThenFailNextClear = false
            throw VPhoneSystemLocationError(
                code: "location_delivery_timeout", message: "test lost clear ACK")
        }
    }

    func waitForSuspendedDelivery() async {
        if deliveryIsSuspended { return }
        await withCheckedContinuation { deliveryStartedWaiters.append($0) }
    }

    func waitForSuspendedActivation() async {
        if activationIsSuspended { return }
        await withCheckedContinuation { activationStartedWaiters.append($0) }
    }

    func waitForSuspendedClear() async {
        if clearIsSuspended { return }
        await withCheckedContinuation { clearStartedWaiters.append($0) }
    }

    func resumeSuspendedActivation() {
        suspendedActivation?.resume()
        suspendedActivation = nil
    }

    func resumeSuspendedClear() {
        suspendedClear?.resume()
        suspendedClear = nil
    }

    func resumeSuspendedDelivery() {
        suspendedDelivery?.resume()
        suspendedDelivery = nil
    }

    func seedGuestDelivery(
        _ fix: VPhoneSystemLocationFix,
        generation: String,
        sequence: Int
    ) {
        let delivery = Delivery(fix: fix, generation: generation, sequence: sequence)
        guestGeneration = generation
        currentFix = fix
        guestLastDelivery = delivery
    }

    func replaceGuestGenerationForTesting(_ generation: String?) {
        guestGeneration = generation
        guestLastDelivery = nil
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

    private func waitForDeliveryTurnWaiter(
        _ controller: VPhoneSystemLocationController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if controller.deliveryTurnWaiterCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("operation did not enter the delivery-turn queue", file: file, line: line)
    }

    private func waitForState(
        _ expectedState: String,
        in controller: VPhoneSystemLocationController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if controller.snapshot()["state"] as? String == expectedState { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(
            "location source did not reach state \(expectedState)",
            file: file,
            line: line)
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

    func testStreamStartDelegatesResidualClearToAtomicGuestActivation() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        guest.residualLocationActive = true
        let controller = VPhoneSystemLocationController(adapter: guest)

        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let desired = try XCTUnwrap(started["desired"] as? [String: Any])

        XCTAssertEqual(guest.events, ["activate:\(generation)"])
        XCTAssertTrue(guest.clears.isEmpty)
        XCTAssertFalse(guest.residualLocationActive)
        XCTAssertEqual(desired["watchdog_s"] as? Double, 60)
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

    func testLostAckRetriesExactFrameBeforeAdvancingSequence() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            now: { clock })
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        guest.applyThenFailNextDelivery = true

        do {
            _ = try await controller.setPaused(true, generation: generation)
            XCTFail("first pause ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        clock = clock.addingTimeInterval(1)
        let paused = try await controller.setPaused(true, generation: generation)

        XCTAssertEqual(guest.deliveryAttempts.map(\.sequence), [0, 1, 1, 2])
        XCTAssertEqual(guest.deliveryAttempts[1], guest.deliveryAttempts[2])
        XCTAssertNotEqual(
            guest.deliveryAttempts[2].fix.timestamp,
            guest.deliveryAttempts[3].fix.timestamp)
        XCTAssertEqual(paused["state"] as? String, "paused")
    }

    func testLostAckBindsProducerSequenceToExactPayload() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let original = fix(0)
        guest.applyThenFailNextDelivery = true

        do {
            _ = try await controller.push(generation: generation, fix: original)
            XCTFail("first producer ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        let attemptsAfterLostAck = guest.deliveryAttempts.count
        do {
            _ = try await controller.push(
                generation: generation,
                fix: fix(0, latitude: 31.21))
            XCTFail("one producer sequence must not identify two payloads")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_sequence_conflict")
        }
        XCTAssertEqual(guest.deliveryAttempts.count, attemptsAfterLostAck)

        let accepted = try await controller.push(
            generation: generation,
            fix: original)
        let applied = try XCTUnwrap(accepted["applied"] as? [String: Any])
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 0)
        XCTAssertEqual(guest.deliveryAttempts.map(\.sequence), [0, 0])
        XCTAssertEqual(guest.deliveryAttempts[0], guest.deliveryAttempts[1])
    }

    func testDefinitiveNACKReleasesPendingProducerAndDelivery() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let rejected = fix(0)
        let corrected = fix(0, latitude: 31.21)
        guest.seedGuestDelivery(
            fix(0, latitude: 30.0),
            generation: generation,
            sequence: 0)

        do {
            _ = try await controller.push(generation: generation, fix: rejected)
            XCTFail("guest should reject the first payload")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_sequence_conflict")
        }
        let accepted = try await controller.push(
            generation: generation,
            fix: corrected)

        XCTAssertEqual(guest.deliveryAttempts.map(\.sequence), [0, 0])
        XCTAssertEqual(guest.deliveryAttempts.map(\.fix), [rejected, corrected])
        XCTAssertEqual(guest.deliveries.map(\.fix), [corrected])
        XCTAssertEqual(guest.activations, [generation, generation])
        let applied = try XCTUnwrap(accepted["applied"] as? [String: Any])
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 0)
    }

    func testReconnectCommitsFirstProducerAfterLostAck() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let pending = fix(0, latitude: 31.21)
        guest.applyThenFailNextDelivery = true

        do {
            _ = try await controller.push(generation: generation, fix: pending)
            XCTFail("producer ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        await controller.reapplyAfterReconnect()

        let status = controller.snapshot()
        let applied = try XCTUnwrap(status["applied"] as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "running")
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 0)
        XCTAssertEqual(guest.currentFix?.latitude, pending.latitude)
        XCTAssertEqual(guest.deliveryAttempts.map(\.sequence), [0, 0])
        let attemptCount = guest.deliveryAttempts.count
        _ = try await controller.push(generation: generation, fix: pending)
        XCTAssertEqual(guest.deliveryAttempts.count, attemptCount)
    }

    func testReconnectCommitsNextProducerWithoutRollingBackCoordinate() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        let pending = fix(1, latitude: 31.21)
        guest.applyThenFailNextDelivery = true

        do {
            _ = try await controller.push(generation: generation, fix: pending)
            XCTFail("producer ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        await controller.reapplyAfterReconnect()

        XCTAssertEqual(guest.currentFix?.latitude, pending.latitude)
        XCTAssertEqual(guest.deliveryAttempts.map(\.sequence), [0, 1, 1])
        let applied = try XCTUnwrap(
            controller.snapshot()["applied"] as? [String: Any])
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 1)
    }

    func testPushWhilePausedUpdatesCoordinateWithoutResuming() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        _ = try await controller.setPaused(true, generation: generation)

        let pushed = try await controller.push(
            generation: generation,
            fix: fix(1, latitude: 31.21))

        XCTAssertEqual(pushed["state"] as? String, "paused")
        XCTAssertEqual(guest.currentFix?.latitude, 31.21)
        XCTAssertEqual(guest.currentFix?.speed, 0)
    }

    func testExactProducerRetryConvergesAfterLostPauseAck() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let acceptedFix = fix(0)
        _ = try await controller.push(
            generation: generation,
            fix: acceptedFix)
        guest.applyThenFailNextDelivery = true

        do {
            _ = try await controller.setPaused(true, generation: generation)
            XCTFail("pause ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        let pendingPause = try XCTUnwrap(guest.deliveryAttempts.last)

        _ = try await controller.push(
            generation: generation,
            fix: acceptedFix)

        let convergingAttempts = Array(guest.deliveryAttempts.suffix(3))
        XCTAssertEqual(convergingAttempts.map(\.sequence), [
            pendingPause.sequence, pendingPause.sequence, pendingPause.sequence + 1,
        ])
        XCTAssertEqual(convergingAttempts.first, convergingAttempts.dropFirst().first)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertEqual(guest.currentFix?.speed, acceptedFix.speed)
    }

    func testFailedReconnectPreservesPauseIntentForNextReconnect() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        _ = try await controller.setPaused(true, generation: generation)
        guest.applyThenFailNextDelivery = true

        do {
            _ = try await controller.push(
                generation: generation,
                fix: fix(1, latitude: 31.21))
            XCTFail("paused producer ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        guest.failuresRemaining = 1
        await controller.reapplyAfterReconnect()
        let failed = controller.snapshot()
        let desired = try XCTUnwrap(failed["desired"] as? [String: Any])
        XCTAssertEqual(failed["state"] as? String, "applying")
        XCTAssertEqual(desired["paused"] as? Bool, true)

        await controller.reapplyAfterReconnect()

        let recovered = controller.snapshot()
        let applied = try XCTUnwrap(recovered["applied"] as? [String: Any])
        XCTAssertEqual(recovered["state"] as? String, "paused")
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 1)
        XCTAssertEqual(guest.currentFix?.latitude, 31.21)
        XCTAssertEqual(guest.currentFix?.speed, 0)
    }

    func testFailedReconnectPreservesWatchdogHoldingForNextReconnect() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 0.5)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        await waitForState("holding", in: controller)

        guest.failuresRemaining = 1
        await controller.reapplyAfterReconnect()
        XCTAssertEqual(controller.snapshot()["state"] as? String, "applying")

        await controller.reapplyAfterReconnect()

        XCTAssertEqual(controller.snapshot()["state"] as? String, "holding")
        XCTAssertEqual(guest.currentFix?.speed, 0)
        XCTAssertTrue(controller.hasScheduledHeartbeat)
    }

    func testCancelledQueuedWatchdogCannotPublishHoldingIntent() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 0.05)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))

        guest.suspendNextActivation = true
        let reconnect = Task { await controller.reapplyAfterReconnect() }
        await guest.waitForSuspendedActivation()
        await waitForDeliveryTurnWaiter(controller)
        guest.resumeSuspendedActivation()
        await reconnect.value

        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertEqual(guest.currentFix?.speed, fix(0).speed)
    }

    func testDefinitiveNACKDuringControlReleasesPendingProducer() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        let pending = fix(1, latitude: 31.21)
        guest.applyThenFailNextDelivery = true

        do {
            _ = try await controller.push(generation: generation, fix: pending)
            XCTFail("producer ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        guest.seedGuestDelivery(
            fix(1, latitude: 30.0),
            generation: generation,
            sequence: 1)
        do {
            _ = try await controller.setPaused(true, generation: generation)
            XCTFail("pending replay should observe the guest conflict")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_sequence_conflict")
        }

        let corrected = fix(1, latitude: 31.22)
        let accepted = try await controller.push(
            generation: generation,
            fix: corrected)
        let applied = try XCTUnwrap(accepted["applied"] as? [String: Any])
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 1)
        XCTAssertEqual(guest.currentFix?.latitude, corrected.latitude)
        XCTAssertEqual(guest.activations, [generation, generation])
    }

    func testCancelledDeliveryWaiterNeverReachesGuest() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        guest.suspendNextDelivery = true

        let nextPush = Task<Void, Error> {
            _ = try await controller.push(
                generation: generation,
                fix: fix(1, latitude: 31.21))
        }
        await guest.waitForSuspendedDelivery()
        let cancelledPause = Task<Void, Error> {
            _ = try await controller.setPaused(true, generation: generation)
        }
        await waitForDeliveryTurnWaiter(controller)
        cancelledPause.cancel()
        guest.resumeSuspendedDelivery()
        _ = try await nextPush.value

        do {
            _ = try await cancelledPause.value
            XCTFail("cancelled queued delivery must not reach the guest")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(guest.deliveryAttempts.map(\.sequence), [0, 1])
        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
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

    func testReplacementWaitsForInFlightDelivery() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let first = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let oldGeneration = try XCTUnwrap(first["generation"] as? String)
        guest.suspendNextDelivery = true

        let oldPush = Task<Void, Error> {
            _ = try await controller.push(generation: oldGeneration, fix: fix(0))
        }
        await guest.waitForSuspendedDelivery()
        let replacement = Task<String, Error> {
            let snapshot = try await controller.startStream(
                owner: "route-2", watchdogSeconds: 60, replace: true)
            return try XCTUnwrap(snapshot["generation"] as? String)
        }
        await waitForDeliveryTurnWaiter(controller)
        XCTAssertEqual(controller.generation, oldGeneration)
        guest.resumeSuspendedDelivery()
        _ = try await oldPush.value
        let replacementGeneration = try await replacement.value
        let current = controller.snapshot()
        let applied = try XCTUnwrap(current["applied"] as? [String: Any])
        XCTAssertNotEqual(replacementGeneration, oldGeneration)
        XCTAssertEqual(current["generation"] as? String, replacementGeneration)
        XCTAssertEqual(current["state"] as? String, "applying")
        XCTAssertEqual(applied["last_delivery_sequence"] as? Int, -1)
        XCTAssertNil(applied["last_producer_sequence"])
        XCTAssertNil(applied["last_fix"])
        XCTAssertEqual(Array(guest.events.suffix(2)), [
            "deliver:\(oldGeneration):0",
            "activate:\(replacementGeneration)",
        ])
    }

    func testStaleExternalOwnershipFailsBeforeQueuedReplacementCommits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let persistedBytes = try Data(contentsOf: stateURL)

        guest.suspendNextDelivery = true
        let inFlightPause = Task<Void, Error> {
            _ = try await controller.setPaused(true, generation: generation)
        }
        await guest.waitForSuspendedDelivery()

        var ownershipRevision = 0
        let replacement = Task<Void, Error> {
            _ = try await controller.startStream(
                owner: "route-1",
                watchdogSeconds: 60,
                replace: true,
                precommit: {
                    guard ownershipRevision == 0 else {
                        throw VPhoneSystemLocationError(
                            code: "location_owner_conflict",
                            message: "GUI source superseded external request")
                    }
                })
        }
        await waitForDeliveryTurnWaiter(controller)
        ownershipRevision = 1
        guest.resumeSuspendedDelivery()
        _ = try await inFlightPause.value

        do {
            _ = try await replacement.value
            XCTFail("stale external ownership must reject replacement")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_owner_conflict")
        }

        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(guest.activations, [generation])
        let desired = try XCTUnwrap(
            controller.snapshot()["desired"] as? [String: Any])
        XCTAssertEqual(desired["mode"] as? String, "fixed")
        XCTAssertEqual(desired["persistent"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: stateURL), persistedBytes)
        XCTAssertEqual(guest.currentFix?.speed, 0)
    }

    func testReplacementWaitsForInFlightActivation() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        guest.suspendNextActivation = true

        let oldSet = Task<Void, Error> {
            _ = try await controller.setFixed(
                owner: "dashboard",
                fix: fix(0),
                heartbeatSeconds: 60)
        }
        await guest.waitForSuspendedActivation()
        let oldGeneration = try XCTUnwrap(controller.generation)
        let replacement = Task<String, Error> {
            let snapshot = try await controller.startStream(
                owner: "route-2", watchdogSeconds: 60, replace: true)
            return try XCTUnwrap(snapshot["generation"] as? String)
        }
        await waitForDeliveryTurnWaiter(controller)
        XCTAssertEqual(controller.generation, oldGeneration)
        guest.resumeSuspendedActivation()
        _ = try await oldSet.value
        let replacementGeneration = try await replacement.value
        let current = controller.snapshot()
        let applied = try XCTUnwrap(current["applied"] as? [String: Any])
        XCTAssertNotEqual(replacementGeneration, oldGeneration)
        XCTAssertEqual(current["generation"] as? String, replacementGeneration)
        XCTAssertEqual(current["state"] as? String, "applying")
        XCTAssertEqual(applied["last_delivery_sequence"] as? Int, -1)
        XCTAssertEqual(Array(guest.events.suffix(2)), [
            "deliver:\(oldGeneration):0",
            "activate:\(replacementGeneration)",
        ])
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

    func testClearLegacyLocationCommitsOwnedPersistentStop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        let started = try await controller.setFixed(
            owner: "legacy-uds",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)

        let cleared = try await controller.clearLegacyLocation()

        XCTAssertEqual(cleared["state"] as? String, "off")
        XCTAssertEqual(guest.clears, [generation])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testLegacyGuestStopFailureKeepsPersistentOwnedSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let rollbackError = VPhoneSystemLocationError(
            code: "location_guest_unavailable",
            message: "old guest does not support owned location sources")

        do {
            _ = try await controller.clearLegacyLocation(
                guestOperation: {
                    try await guest.clear(generation: nil)
                    throw VPhoneSystemLocationError(
                        code: "location_delivery_timeout",
                        message: "legacy stop ACK was lost")
                },
                guestRollback: { _ in
                    throw rollbackError
                })
            XCTFail("failed legacy stop must retain the owned source")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }

        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "applying")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertNil(guest.currentFix)
        XCTAssertEqual(guest.activations, [generation])
        let restored = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        XCTAssertTrue(restored.hasActiveSource)
    }

    func testLegacyCommitFailureRestoresPersistedFixThroughRawGuest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let store = VPhoneSystemLocationStateStore(
            url: stateURL,
            beforeCommitClear: {
                throw VPhoneSystemLocationError(
                    code: "test_commit_failure", message: "test commit failure")
            })
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: store)
        let originalFix = fix(0)
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: originalFix,
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)
        var rawGuestFix: VPhoneSystemLocationFix? = originalFix
        var rollbackFix: VPhoneSystemLocationFix?

        do {
            _ = try await controller.clearLegacyLocation(
                guestOperation: {
                    rawGuestFix = nil
                },
                guestRollback: { fix in
                    rollbackFix = fix
                    rawGuestFix = fix
                })
            XCTFail("persistence commit failure must reject legacy stop")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_persistence_failed")
        }

        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "applying")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(rollbackFix?.latitude, originalFix.latitude)
        XCTAssertEqual(rollbackFix?.speed, originalFix.speed)
        XCTAssertEqual(rawGuestFix?.latitude, originalFix.latitude)
    }

    func testFailedRawRollbackMakesExactProducerRetryRebindGuest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let store = VPhoneSystemLocationStateStore(
            url: stateURL,
            beforeCommitClear: {
                throw VPhoneSystemLocationError(
                    code: "test_commit_failure", message: "test commit failure")
            })
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: store)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let acceptedFix = fix(0)
        _ = try await controller.push(
            generation: generation,
            fix: acceptedFix)

        do {
            _ = try await controller.clearLegacyLocation(
                guestOperation: {
                    try await guest.clear(generation: nil)
                },
                guestRollback: { _ in
                    throw VPhoneSystemLocationError(
                        code: "location_guest_unavailable",
                        message: "raw rollback failed")
                })
            XCTFail("persistence commit failure must reject legacy clear")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_persistence_failed")
        }
        XCTAssertNil(guest.currentFix)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "applying")

        guest.applyThenFailNextDelivery = true
        do {
            _ = try await controller.push(
                generation: generation,
                fix: acceptedFix)
            XCTFail("repair ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        let pendingRepair = try XCTUnwrap(guest.deliveryAttempts.last)

        _ = try await controller.push(generation: generation, fix: acceptedFix)

        XCTAssertEqual(guest.activations, [generation, generation])
        XCTAssertEqual(guest.deliveryAttempts.suffix(2).map(\.sequence), [
            pendingRepair.sequence, pendingRepair.sequence,
        ])
        XCTAssertEqual(guest.deliveryAttempts.suffix(2).map(\.fix), [
            pendingRepair.fix, pendingRepair.fix,
        ])
        XCTAssertEqual(guest.currentFix?.latitude, acceptedFix.latitude)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
    }

    func testReplacementWaitsForInFlightStop() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let first = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let oldGeneration = try XCTUnwrap(first["generation"] as? String)
        guest.suspendNextClear = true

        let oldStop = Task<Void, Error> {
            _ = try await controller.stop(generation: oldGeneration)
        }
        await guest.waitForSuspendedClear()
        let replacement = Task<String, Error> {
            let snapshot = try await controller.startStream(
                owner: "route-2", watchdogSeconds: 60, replace: true)
            return try XCTUnwrap(snapshot["generation"] as? String)
        }
        await waitForDeliveryTurnWaiter(controller)
        XCTAssertEqual(controller.generation, oldGeneration)
        guest.resumeSuspendedClear()
        _ = try await oldStop.value
        let replacementGeneration = try await replacement.value
        let current = controller.snapshot()
        XCTAssertNotEqual(replacementGeneration, oldGeneration)
        XCTAssertEqual(current["generation"] as? String, replacementGeneration)
        XCTAssertEqual(current["state"] as? String, "applying")
        XCTAssertEqual(Array(guest.events.suffix(2)), [
            "clear:\(oldGeneration)",
            "activate:\(replacementGeneration)",
        ])
    }

    func testGUIRelinquishDuringStopCannotRestorePersistentSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        let pendingURL = stateURL.appendingPathExtension("pending-delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)
        guest.suspendNextClear = true
        let stop = Task<Void, Error> {
            _ = try await controller.stop(generation: generation)
        }
        await guest.waitForSuspendedClear()

        controller.relinquishForGUI()
        guest.resumeSuspendedClear()

        do {
            try await stop.value
            XCTFail("GUI relinquish must invalidate the in-flight stop")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_generation_conflict")
        }
        XCTAssertFalse(controller.hasActiveSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        let restored = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        XCTAssertFalse(restored.hasActiveSource)
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

    func testHoldingHeartbeatConfirmsMovingProducerWithoutFreezingItAgain() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 0.2)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        await waitForState("holding", in: controller)

        let movingFix = fix(1, latitude: 31.21)
        guest.applyThenFailNextDelivery = true
        do {
            _ = try await controller.push(
                generation: generation,
                fix: movingFix)
            XCTFail("producer ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }

        await waitForState("running", in: controller)

        let applied = try XCTUnwrap(
            controller.snapshot()["applied"] as? [String: Any])
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 1)
        XCTAssertEqual(guest.currentFix?.latitude, movingFix.latitude)
        XCTAssertEqual(guest.currentFix?.speed, movingFix.speed)
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

    func testReconnectReapplyCannotUndoLaterResume() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        _ = try await controller.setPaused(true, generation: generation)
        guest.suspendNextActivation = true

        let reconnect = Task { await controller.reapplyAfterReconnect() }
        await guest.waitForSuspendedActivation()
        let deliveryCountBeforeResume = guest.deliveryAttempts.count
        let resume = Task<Void, Error> {
            _ = try await controller.setPaused(false, generation: generation)
        }
        await waitForDeliveryTurnWaiter(controller)
        guest.resumeSuspendedActivation()
        await reconnect.value
        try await resume.value

        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertEqual(guest.deliveryAttempts.count, deliveryCountBeforeResume + 2)
        XCTAssertEqual(guest.deliveryAttempts.last?.fix.speed, 10)
    }

    func testQueuedReconnectCannotUndoPauseThatFinishesFirst() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        guest.suspendNextDelivery = true

        let pause = Task<Void, Error> {
            _ = try await controller.setPaused(true, generation: generation)
        }
        await guest.waitForSuspendedDelivery()
        let reconnect = Task { await controller.reapplyAfterReconnect() }
        await waitForDeliveryTurnWaiter(controller)
        guest.resumeSuspendedDelivery()
        try await pause.value
        await reconnect.value

        XCTAssertEqual(controller.snapshot()["state"] as? String, "paused")
        XCTAssertEqual(guest.currentFix?.speed, 0)
    }

    func testQueuedReconnectCannotUndoResumeThatFinishesFirst() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        _ = try await controller.setPaused(true, generation: generation)
        guest.suspendNextDelivery = true

        let resume = Task<Void, Error> {
            _ = try await controller.setPaused(false, generation: generation)
        }
        await guest.waitForSuspendedDelivery()
        let reconnect = Task { await controller.reapplyAfterReconnect() }
        await waitForDeliveryTurnWaiter(controller)
        guest.resumeSuspendedDelivery()
        try await resume.value
        await reconnect.value

        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertEqual(guest.currentFix?.speed, 10)
    }

    func testFixedHeartbeatCannotUndoPauseWhileWaitingForDeliveryTurn() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 0.05)
        let generation = try XCTUnwrap(started["generation"] as? String)
        guest.suspendNextDelivery = true

        let pause = Task<Void, Error> {
            _ = try await controller.setPaused(true, generation: generation)
        }
        await guest.waitForSuspendedDelivery()
        defer { guest.resumeSuspendedDelivery() }
        try await Task.sleep(for: .milliseconds(70))
        await waitForDeliveryTurnWaiter(controller)
        guest.resumeSuspendedDelivery()
        try await pause.value
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(controller.snapshot()["state"] as? String, "paused")
        XCTAssertEqual(guest.currentFix?.speed, 0)
        _ = try await controller.stop(generation: generation)
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

        let originalGeneration: String
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
            originalGeneration = try XCTUnwrap(snapshot["generation"] as? String)
            let desired = try XCTUnwrap(snapshot["desired"] as? [String: Any])
            XCTAssertEqual(desired["persistent"] as? Bool, true)
            XCTAssertEqual(desired["heartbeat_s"] as? Double, 60)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        }

        let restoredGuest = FakeSystemLocationGuestAdapter()
        let restored = VPhoneSystemLocationController(
            adapter: restoredGuest,
            stateStore: store)
        let before = restored.snapshot()
        let restoredGeneration = try XCTUnwrap(before["generation"] as? String)
        XCTAssertNotEqual(restoredGeneration, originalGeneration)
        XCTAssertEqual(before["state"] as? String, "applying")
        await restored.reapplyAfterReconnect()

        XCTAssertEqual(restoredGuest.activations, [restoredGeneration])
        XCTAssertEqual(restoredGuest.deliveries.count, 1)
        XCTAssertEqual(restored.snapshot()["state"] as? String, "running")

        restored.relinquishForGUI()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testCorruptInstanceDoesNotChangeOtherInstancesPersistedSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first/system-location.json")
        let secondURL = directory.appendingPathComponent("second/system-location.json")
        let first = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: VPhoneSystemLocationStateStore(url: firstURL))
        let secondGuest = FakeSystemLocationGuestAdapter()
        let second = VPhoneSystemLocationController(
            adapter: secondGuest,
            stateStore: VPhoneSystemLocationStateStore(url: secondURL))
        _ = try await first.setFixed(owner: "first", fix: fix(0),
                                     heartbeatSeconds: 60, persist: true)
        _ = try await second.setFixed(owner: "second", fix: fix(0, latitude: 35),
                                      heartbeatSeconds: 60, persist: true)
        let secondBytes = try Data(contentsOf: secondURL)
        let secondGeneration = second.generation
        let corruptBytes = Data("{truncated".utf8)
        try corruptBytes.write(to: firstURL)

        let failedGuest = FakeSystemLocationGuestAdapter()
        let restored = VPhoneSystemLocationController(
            adapter: failedGuest,
            stateStore: VPhoneSystemLocationStateStore(url: firstURL))
        await restored.reapplyAfterReconnect()
        XCTAssertFalse(restored.hasActiveSource)
        XCTAssertTrue(failedGuest.activations.isEmpty)
        let applied = try XCTUnwrap(restored.snapshot()["applied"] as? [String: Any])
        let error = try XCTUnwrap(applied["last_error"] as? [String: String])
        XCTAssertEqual(error["code"], "location_persistence_corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        let quarantine = try FileManager.default.contentsOfDirectory(
            at: firstURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("system-location.json.corrupt-") }
        XCTAssertEqual(quarantine.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantine.first)), corruptBytes)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)
        XCTAssertEqual(second.generation, secondGeneration)
        XCTAssertEqual(secondGuest.currentFix?.latitude, 35)
    }

    func testStreamReplacingPersistentFixedSourceDoesNotRestoreAfterReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("system-location.json")
        let controller = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: VPhoneSystemLocationStateStore(url: url))
        _ = try await controller.setFixed(owner: "fixed", fix: fix(0),
                                          heartbeatSeconds: 60, persist: true)
        let stream = try await controller.startStream(
            owner: "stream", watchdogSeconds: 60, replace: true)
        let generation = try XCTUnwrap(stream["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0, latitude: 35))
        let restoredGuest = FakeSystemLocationGuestAdapter()
        let restored = VPhoneSystemLocationController(
            adapter: restoredGuest,
            stateStore: VPhoneSystemLocationStateStore(url: url))
        await restored.reapplyAfterReconnect()
        XCTAssertEqual(restored.snapshot()["state"] as? String, "off")
        XCTAssertNil(restored.generation)
        XCTAssertTrue(restoredGuest.activations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        _ = try await controller.stop(generation: generation)
    }

    func testInterruptedPersistenceClearRestoresOnNextLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        let pendingURL = stateURL.appendingPathExtension("pending-delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VPhoneSystemLocationStateStore(url: stateURL)
        let controller = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: store)
        _ = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)

        _ = try store.stageClear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))

        let restored = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        XCTAssertTrue(restored.hasActiveSource)
        XCTAssertEqual(restored.snapshot()["state"] as? String, "applying")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
    }

    func testCommittedPersistenceClearDoesNotRestoreOnNextLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VPhoneSystemLocationStateStore(url: stateURL)
        let controller = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: store)
        _ = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)

        let staged = try store.stageClear()
        try store.commitClear(staged)

        let restored = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        XCTAssertFalse(restored.hasActiveSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testNewPersistentCandidateSupersedesInterruptedClear() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        let pendingURL = stateURL.appendingPathExtension("pending-delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VPhoneSystemLocationStateStore(url: stateURL)
        let controller = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: store)
        _ = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        _ = try store.stageClear()

        _ = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0, latitude: 32.1),
            heartbeatSeconds: 60,
            persist: true)

        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
                as? [String: Any])
        let persistedFix = try XCTUnwrap(persisted["fix"] as? [String: Any])
        XCTAssertEqual(persistedFix["latitude"] as? Double, 32.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        let restored = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        XCTAssertTrue(restored.hasActiveSource)
    }

    func testRelinquishForGUISupersedesInterruptedClear() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        let pendingURL = stateURL.appendingPathExtension("pending-delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VPhoneSystemLocationStateStore(url: stateURL)
        let controller = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: store)
        _ = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        _ = try store.stageClear()

        controller.relinquishForGUI()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        let restored = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        XCTAssertFalse(restored.hasActiveSource)
    }

    func testRelinquishForGUIFailsClosedWhenPersistenceCannotBeRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let store = VPhoneSystemLocationStateStore(
            url: stateURL,
            beforeClear: {
                throw VPhoneSystemLocationError(
                    code: "test_clear_failure", message: "test clear failure")
            },
            beforeQuarantine: {
                throw VPhoneSystemLocationError(
                    code: "test_quarantine_failure", message: "test quarantine failure")
            })
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: store)
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)

        let relinquished = controller.relinquishForGUI()

        XCTAssertFalse(relinquished)
        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(guest.currentFix?.latitude, fix(0).latitude)
    }

    func testStopPersistenceStageFailureHasNoGuestSideEffect() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let store = VPhoneSystemLocationStateStore(
            url: stateURL,
            beforeStageClear: {
                throw VPhoneSystemLocationError(
                    code: "test_stage_failure", message: "test stage failure")
            })
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: store)
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)
        let originalState = try Data(contentsOf: stateURL)

        do {
            _ = try await controller.stop(generation: generation)
            XCTFail("persistence stage failure must reject stop")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_persistence_failed")
        }

        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertEqual(try Data(contentsOf: stateURL), originalState)
        XCTAssertTrue(guest.clears.isEmpty)
        XCTAssertEqual(guest.currentFix?.latitude, fix(0).latitude)
    }

    func testStopLostClearAckRestoresPersistentSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)
        guest.applyThenFailNextClear = true

        do {
            _ = try await controller.stop(generation: generation)
            XCTFail("lost clear ACK must leave stop uncommitted")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }

        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(guest.currentFix?.latitude, fix(0).latitude)
        XCTAssertEqual(guest.activations, [generation, generation])
    }

    func testStopGenerationConflictRebindsPersistentSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)
        guest.replaceGuestGenerationForTesting("other-generation")

        do {
            _ = try await controller.stop(generation: generation)
            XCTFail("stale guest ownership must reject stop")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_generation_conflict")
        }

        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(guest.currentFix?.latitude, fix(0).latitude)
        XCTAssertEqual(guest.activations, [generation, generation])
    }

    func testStopUnavailableAfterAppliedClearRebindsPersistentSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)
        guest.applyThenFailNextClearError = VPhoneSystemLocationError(
            code: "location_guest_unavailable",
            message: "clear selector threw after applying",
            definitiveGuestRejection: true)

        do {
            _ = try await controller.stop(generation: generation)
            XCTFail("applied clear failure must leave stop uncommitted")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_guest_unavailable")
        }

        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(guest.currentFix?.latitude, fix(0).latitude)
        XCTAssertEqual(guest.activations, [generation, generation])
    }

    func testFailedPausedStopRepairPreservesPauseIntent() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 60)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))
        _ = try await controller.setPaused(true, generation: generation)

        guest.failuresRemaining = 1
        await controller.reapplyAfterReconnect()
        XCTAssertEqual(controller.snapshot()["state"] as? String, "applying")
        XCTAssertEqual(
            (controller.snapshot()["desired"] as? [String: Any])?["paused"] as? Bool,
            true)

        guest.applyThenFailNextClear = true
        do {
            _ = try await controller.stop(generation: generation)
            XCTFail("lost clear ACK must leave stop uncommitted")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }

        XCTAssertEqual(controller.snapshot()["state"] as? String, "paused")
        XCTAssertEqual(guest.currentFix?.speed, 0)
        XCTAssertEqual(guest.activations.suffix(2), [generation, generation])
    }

    func testFailedFixedStopRepairRestartsMissingHeartbeat() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        guest.failuresRemaining = 1

        do {
            _ = try await controller.setFixed(
                owner: "dashboard",
                fix: fix(0),
                heartbeatSeconds: 0.01)
            XCTFail("initial fixed delivery should time out")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        let generation = try XCTUnwrap(controller.generation)

        guest.applyThenFailNextClear = true
        do {
            _ = try await controller.stop(generation: generation)
            XCTFail("lost clear ACK must leave stop uncommitted")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }
        XCTAssertTrue(controller.hasScheduledHeartbeat)
        _ = try await controller.stop(generation: generation)
    }

    func testHoldingLostAckStopRepairCommitsMovingProducer() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 0.2)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))

        await waitForState("holding", in: controller)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "holding")

        let movingFix = fix(1, latitude: 31.21)
        guest.applyThenFailNextDelivery = true
        do {
            _ = try await controller.push(
                generation: generation,
                fix: movingFix)
            XCTFail("moving producer ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }

        guest.applyThenFailNextClear = true
        do {
            _ = try await controller.stop(generation: generation)
            XCTFail("lost clear ACK must leave stop uncommitted")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }

        let snapshot = controller.snapshot()
        let applied = try XCTUnwrap(snapshot["applied"] as? [String: Any])
        XCTAssertEqual(snapshot["state"] as? String, "running")
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 1)
        XCTAssertEqual(guest.currentFix?.latitude, movingFix.latitude)
        XCTAssertEqual(guest.currentFix?.speed, movingFix.speed)
    }

    func testRestoredFixedSourceRetriesAfterInitialReapplyFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VPhoneSystemLocationStateStore(url: stateURL)
        var writer: VPhoneSystemLocationController? = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: store)
        _ = try await writer?.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 0.01,
            persist: true)
        writer = nil

        let guest = FakeSystemLocationGuestAdapter()
        guest.failuresRemaining = 1
        let restored = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: store)
        XCTAssertFalse(restored.hasScheduledHeartbeat)

        await restored.reapplyAfterReconnect()
        XCTAssertEqual(restored.snapshot()["state"] as? String, "applying")
        XCTAssertTrue(restored.hasScheduledHeartbeat)

        await waitForState("running", in: restored)
        XCTAssertEqual(restored.snapshot()["state"] as? String, "running")
        XCTAssertEqual(guest.currentFix?.latitude, fix(0).latitude)
        _ = try await restored.stop(generation: restored.generation)
    }

    func testFailedPendingProducerReapplyRetriesPendingProducer() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1", watchdogSeconds: 0.05)
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))

        let pendingFix = fix(1, latitude: 31.21)
        guest.applyThenFailNextDelivery = true
        do {
            _ = try await controller.push(
                generation: generation,
                fix: pendingFix)
            XCTFail("producer ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }

        guest.failuresRemaining = 1
        await controller.reapplyAfterReconnect()
        XCTAssertEqual(controller.snapshot()["state"] as? String, "applying")

        await waitForState("running", in: controller)
        let applied = try XCTUnwrap(
            controller.snapshot()["applied"] as? [String: Any])
        XCTAssertEqual(applied["last_producer_sequence"] as? Int, 1)
        XCTAssertEqual(guest.currentFix?.latitude, pendingFix.latitude)
    }

    func testPendingReapplyRetryPreservesStopWatchdog() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)
        let started = try await controller.startStream(
            owner: "route-1",
            watchdogSeconds: 0.05,
            onTimeout: "stop")
        let generation = try XCTUnwrap(started["generation"] as? String)
        _ = try await controller.push(generation: generation, fix: fix(0))

        guest.applyThenFailNextDelivery = true
        do {
            _ = try await controller.push(
                generation: generation,
                fix: fix(1, latitude: 31.21))
            XCTFail("producer ACK should be lost")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }

        guest.failuresRemaining = 100
        await controller.reapplyAfterReconnect()
        XCTAssertEqual(controller.snapshot()["state"] as? String, "applying")

        await waitForState("off", in: controller)
        XCTAssertNil(controller.generation)
        XCTAssertEqual(guest.clears, [generation])
    }

    func testStopCommitFailureRollsBackFileAndGuest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let store = VPhoneSystemLocationStateStore(
            url: stateURL,
            beforeCommitClear: {
                throw VPhoneSystemLocationError(
                    code: "test_commit_failure", message: "test commit failure")
            })
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: store)
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)

        do {
            _ = try await controller.stop(generation: generation)
            XCTFail("persistence commit failure must reject stop")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_persistence_failed")
        }

        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(guest.currentFix?.latitude, fix(0).latitude)
        XCTAssertEqual(guest.activations, [generation, generation])
    }

    func testStopRollbackFailureLeavesRecoverableSidecar() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        let pendingURL = stateURL.appendingPathExtension("pending-delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let store = VPhoneSystemLocationStateStore(
            url: stateURL,
            beforeRollbackClear: {
                throw VPhoneSystemLocationError(
                    code: "test_rollback_failure", message: "test rollback failure")
            })
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: store)
        let started = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let generation = try XCTUnwrap(started["generation"] as? String)
        guest.applyThenFailNextClear = true

        do {
            _ = try await controller.stop(generation: generation)
            XCTFail("rollback failure must leave stop uncommitted")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_persistence_failed")
        }

        XCTAssertEqual(controller.generation, generation)
        XCTAssertEqual(controller.snapshot()["state"] as? String, "applying")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertEqual(guest.currentFix?.latitude, fix(0).latitude)
        XCTAssertEqual(guest.activations, [generation, generation])
        let restored = VPhoneSystemLocationController(
            adapter: FakeSystemLocationGuestAdapter(),
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        XCTAssertTrue(restored.hasActiveSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testPersistedUnsafeHeartbeatIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let encodedState = """
        {
          "schemaVersion": 1,
          "owner": "dashboard",
          "fix": {
            "producerSequence": 0,
            "latitude": 31.2,
            "longitude": 118.8,
            "altitude": 0,
            "horizontalAccuracy": 5,
            "verticalAccuracy": 8,
            "speed": 0,
            "course": -1,
            "timestamp": 1700000000
          },
          "heartbeatSeconds": 1e308
        }
        """
        try Data(encodedState.utf8).write(to: stateURL)
        let guest = FakeSystemLocationGuestAdapter()

        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))

        let snapshot = controller.snapshot()
        let applied = try XCTUnwrap(snapshot["applied"] as? [String: Any])
        let lastError = try XCTUnwrap(applied["last_error"] as? [String: String])
        XCTAssertFalse(controller.hasActiveSource)
        XCTAssertEqual(lastError["code"], "location_persistence_corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix("system-location.json.corrupt-") })
        XCTAssertTrue(guest.activations.isEmpty)
    }

    func testOwnerConflictDoesNotChangePersistentFixedSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        let original = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let originalGeneration = try XCTUnwrap(original["generation"] as? String)
        let originalState = try Data(contentsOf: stateURL)

        do {
            _ = try await controller.startStream(
                owner: "route-2",
                watchdogSeconds: 60)
            XCTFail("other owner should require replace")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_owner_conflict")
        }

        let current = controller.snapshot()
        let desired = try XCTUnwrap(current["desired"] as? [String: Any])
        XCTAssertEqual(current["generation"] as? String, originalGeneration)
        XCTAssertEqual(desired["owner"] as? String, "dashboard")
        XCTAssertEqual(desired["persistent"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: stateURL), originalState)
        XCTAssertEqual(guest.activations, [originalGeneration])
    }

    func testOwnedCapabilityFailureDoesNotChangePersistentSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
        let original = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        let originalGeneration = try XCTUnwrap(original["generation"] as? String)
        let originalState = try Data(contentsOf: stateURL)
        guest.availabilityError = VPhoneSystemLocationError(
            code: "location_guest_unavailable",
            message: "guest does not support owned location sources")

        do {
            _ = try await controller.startStream(
                owner: "dashboard",
                watchdogSeconds: 60)
            XCTFail("owned source should require the owned guest capability")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_guest_unavailable")
        }

        let current = controller.snapshot()
        let desired = try XCTUnwrap(current["desired"] as? [String: Any])
        XCTAssertEqual(current["generation"] as? String, originalGeneration)
        XCTAssertEqual(desired["mode"] as? String, "fixed")
        XCTAssertEqual(desired["persistent"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: stateURL), originalState)
        XCTAssertEqual(guest.activations, [originalGeneration])
        XCTAssertTrue(guest.clears.isEmpty)
    }

    func testPersistentFixedCandidateSurvivesLostInitialAck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-location-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("system-location.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VPhoneSystemLocationStateStore(url: stateURL)
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(
            adapter: guest,
            stateStore: store)
        _ = try await controller.setFixed(
            owner: "dashboard",
            fix: fix(0),
            heartbeatSeconds: 60,
            persist: true)
        guest.failuresRemaining = 1

        do {
            _ = try await controller.setFixed(
                owner: "dashboard",
                fix: fix(0, latitude: 32.1),
                heartbeatSeconds: 60,
                persist: true)
            XCTFail("initial delivery should time out")
        } catch let error as VPhoneSystemLocationError {
            XCTAssertEqual(error.code, "location_delivery_timeout")
        }

        let current = controller.snapshot()
        let desired = try XCTUnwrap(current["desired"] as? [String: Any])
        XCTAssertEqual(current["state"] as? String, "applying")
        XCTAssertEqual(desired["persistent"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
                as? [String: Any])
        let persistedFix = try XCTUnwrap(persisted["fix"] as? [String: Any])
        XCTAssertEqual(persistedFix["latitude"] as? Double, 32.1)
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

    func testFixedSourceRejectsUnsafeHeartbeatBeforeGuestActivation() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)

        for seconds in [1e-20, 1e308] {
            do {
                _ = try await controller.setFixed(
                    owner: "dashboard",
                    fix: fix(0),
                    heartbeatSeconds: seconds)
                XCTFail("unsafe heartbeat should be rejected: \(seconds)")
            } catch let error as VPhoneSystemLocationError {
                XCTAssertEqual(error.code, "invalid_location_source")
            }
        }
        XCTAssertTrue(guest.activations.isEmpty)
    }

    func testStreamRejectsUnsafeWatchdogBeforeGuestActivation() async throws {
        let guest = FakeSystemLocationGuestAdapter()
        let controller = VPhoneSystemLocationController(adapter: guest)

        for seconds in [1e-20, 1e308] {
            do {
                _ = try await controller.startStream(
                    owner: "route-1",
                    watchdogSeconds: seconds)
                XCTFail("unsafe watchdog should be rejected: \(seconds)")
            } catch let error as VPhoneSystemLocationError {
                XCTAssertEqual(error.code, "invalid_location_source")
            }
        }
        XCTAssertTrue(guest.activations.isEmpty)
    }
}

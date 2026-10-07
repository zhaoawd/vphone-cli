import Foundation
import Testing
@testable import VPhoneAPIKit

@MainActor
struct StartupUnlockTests {
    private func snapshot(_ instance: UUID = UUID(), generation: UUID = UUID(), setup: VPhoneJSONValue? = .bool(false),
                          caps: [String] = ["session_identity", "screen_unlock", "display"]) throws -> VPhoneAPISession.Snapshot {
        var value: [String: VPhoneJSONValue] = ["status": .string("ok"), "api_version": .number(1),
            "instance_id": .string(instance.uuidString), "binary_hash": .string(String(repeating: "a", count: 64)),
            "capabilities": .array(caps.map(VPhoneJSONValue.string))]
        value["setup_pending"] = setup
        let health = try VPhoneAPIHealth.decode(JSONEncoder().encode(VPhoneJSONValue.object(value)), requiredCapabilities: [], expectedBinaryHash: nil)
        return .init(vmInstanceID: "vm", state: .ready, generation: generation, health: health, errorCode: nil)
    }

    @Test func defaultOffAndEnablingCurrentInstanceDoesNotUnlock() async throws {
        var calls = 0
        let unlock = VPhoneStartupUnlock { _, _, _ in calls += 1; return .object(["was_locked": .bool(true)]) }
        let first = try snapshot()
        unlock.observe(first)
        #expect(unlock.operation == nil)
        unlock.setEnabled(true)
        unlock.observe(first)
        #expect(unlock.operation == nil)
        let next = try snapshot()
        unlock.observe(next)
        await unlock.operation?.value
        #expect(calls == 1)
        unlock.observe(try snapshot(UUID(uuidString: next.health!.instanceID!)!))
        #expect(calls == 1)
        unlock.stop()
    }

    @Test func setupPendingUnknownAndMissingCapabilitySkipAutomaticWork() async throws {
        for setup: VPhoneJSONValue? in [nil, .bool(true)] {
            let unlock = VPhoneStartupUnlock(enabled: true) { _, _, _ in Issue.record("unlock must be skipped"); return .null }
            unlock.observe(try snapshot(setup: setup))
            #expect(unlock.operation == nil)
        }
        let unlock = VPhoneStartupUnlock(enabled: true) { _, _, _ in Issue.record("missing capability"); return .null }
        unlock.observe(try snapshot(caps: ["session_identity", "display"]))
        #expect(unlock.operation == nil)
        #expect(throws: VPhoneAPIError.self) { try snapshot(setup: .number(0)) }
    }

    @Test func earlyUnlockedStateIsObservedBeforeLaterLockAndRetry() async throws {
        var calls: [String] = []
        let unlock = VPhoneStartupUnlock(enabled: true, timing: .init(window: .milliseconds(50), poll: .milliseconds(1))) { method, _, _ in
            calls.append(method)
            if method == "device.screen" { return .object(["locked": .bool(true)]) }
            return .object(["was_locked": .bool(calls.count > 1)])
        }
        unlock.observe(try snapshot())
        await unlock.operation?.value
        #expect(calls == ["screen.unlock", "device.screen", "screen.unlock"])
    }

    @Test func stopDisconnectDisableAndReplacementDiscardLateReply() async throws {
        for action in 0..<4 {
            var blocked: CheckedContinuation<VPhoneJSONValue, any Error>?
            var calls = 0
            let unlock = VPhoneStartupUnlock(enabled: true, timing: .init(window: .milliseconds(50), poll: .milliseconds(1))) { _, _, _ in
                calls += 1
                return try await withCheckedThrowingContinuation { blocked = $0 }
            }
            let first = try snapshot()
            unlock.observe(first)
            let task = unlock.operation
            for _ in 0..<100 { if blocked != nil { break }; await Task.yield() }
            let pending = try #require(blocked)
            switch action {
            case 0: unlock.stop()
            case 1: unlock.observe(.init(vmInstanceID: "vm", state: .reconnecting, generation: nil, health: nil, errorCode: "transport"))
            case 2: unlock.setEnabled(false)
            default:
                // A new transport generation must invalidate the old request even for the same instance.
                unlock.observe(try snapshot(UUID(uuidString: first.health!.instanceID!)!))
            }
            pending.resume(returning: .object(["was_locked": .bool(false)]))
            await task?.value
            #expect(calls == 1)
            unlock.stop()
        }
    }
}

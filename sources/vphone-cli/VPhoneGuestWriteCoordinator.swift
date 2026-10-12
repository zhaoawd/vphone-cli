import Foundation
import VPhoneAPIKit
import VPhoneCore

/// One instance per running VM. Only guest maintenance writers use this queue.
@MainActor
final class VPhoneGuestWriteCoordinator {
    private let directory: URL?
    private var active = false
    private var sealed = false
    private var stopping = false
    private var lease: VPhoneOnlineOperationLock?
    private(set) var pendingRecovery = false
    private var recovery: VPhoneGuestEnvironmentRecovery?
    private var recoveryID: UUID?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopped: [CheckedContinuation<Void, Never>] = []
    private(set) var operationID: String?

    nonisolated init(directory: URL? = nil) { self.directory = directory }

    func run<T>(_ body: () async throws -> T) async throws -> T {
        guard !sealed else { throw VPhoneGuestEnvironmentRefusal("guest_writes_stopped", "VM guest writes are stopped") }
        if active { await withCheckedContinuation { waiters.append($0) } }
        else { active = true }
        defer { release() }
        try Task.checkCancellation()
        guard !sealed else { throw VPhoneGuestEnvironmentRefusal("guest_writes_stopped", "VM guest writes are stopped") }
        lease = try directory.map { try VPhoneOnlineOperationLock(directory: $0) }
        operationID = UUID().uuidString.lowercased()
        return try await body()
    }

    /// Seals synchronously before the first suspension; queued writers refuse.
    func sealAndWait() async {
        stopping = true
        sealed = true
        if active || pendingRecovery { await withCheckedContinuation { stopped.append($0) } }
    }

    /// Retain the cross-process lease after an uncertain submitted write.
    /// The record is comparison data, never a reusable source authorization.
    func retainForRecovery(_ record: VPhoneGuestEnvironmentRecovery? = nil) {
        sealed = true
        pendingRecovery = true
        recovery = record
        recoveryID = UUID()
    }

    func reconcile(_ session: (any VPhoneHostAPISession)?) async {
        guard pendingRecovery, !active, let recovery, let recoveryID, let session else { return }
        guard await recovery.hasTerminated(session), pendingRecovery, !active,
              self.recoveryID == recoveryID else { return }
        self.recovery = nil
        self.recoveryID = nil
        pendingRecovery = false
        lease = nil
        sealed = stopping
        let continuations = stopped
        stopped.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func release() {
        operationID = nil
        if !pendingRecovery { lease = nil }
        if !waiters.isEmpty { waiters.removeFirst().resume() }
        else {
            active = false
            guard !pendingRecovery else { return }
            let continuations = stopped
            stopped.removeAll()
            continuations.forEach { $0.resume() }
        }
    }
}

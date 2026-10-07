import Foundation
import VPhoneCore

/// Classic clipboard reads carry image bytes in the same request. The lease
/// covers that complete await; no guest counter is reused across a connection.
@MainActor
final class VPhoneClipboardFocusSync {
    struct Identity: Equatable {
        let connection: UInt64
        let revision: UInt64
    }
    private struct Baseline {
        let identity: Identity
        let count: Int
        let macCount: Int
    }
    private let identity: () -> Identity?
    private let read: @MainActor () async throws -> VPhoneControl.ClipboardContent
    private let macChangeCount: () -> Int
    private let write: (VPhoneControl.ClipboardContent) -> Void
    private var baseline: Baseline?
    private var observedConnection: UInt64?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var isKey = false
    private var stopped = false

    init(identity: @escaping () -> Identity?, read: @escaping @MainActor () async throws -> VPhoneControl.ClipboardContent,
         macChangeCount: @escaping () -> Int, write: @escaping (VPhoneControl.ClipboardContent) -> Void) {
        self.identity = identity
        self.read = read
        self.macChangeCount = macChangeCount
        self.write = write
    }

    @discardableResult
    func focusChanged(key: Bool) -> Task<Void, Never>? {
        guard !stopped else { return nil }
        isKey = key
        invalidate()
        return key ? adopt() : bringCopy()
    }

    func connectionChanged() {
        let current = identity()?.connection
        guard current != observedConnection else { return }
        observedConnection = current
        baseline = nil
        invalidate()
        if isKey { _ = adopt() }
    }

    @discardableResult
    func clipboardMutated() -> Task<Void, Never>? {
        guard !stopped else { return nil }
        baseline = nil
        invalidate()
        return isKey ? adopt() : nil
    }

    func stop() {
        stopped = true
        baseline = nil
        invalidate()
    }

    private func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    private func adopt() -> Task<Void, Never>? {
        baseline = nil
        guard let owner = identity() else { return nil }
        observedConnection = owner.connection
        let lease = generation, mac = macChangeCount()
        task = Task { [weak self] in
            guard let self, let info = try? await read(), !Task.isCancelled,
                  generation == lease, identity() == owner, macChangeCount() == mac,
                  let count = info.changeCount, count >= 0 else { return }
            baseline = Baseline(identity: owner, count: count, macCount: mac)
        }
        return task
    }

    private func bringCopy() -> Task<Void, Never>? {
        guard let baseline, let owner = identity(), baseline.identity == owner,
              baseline.macCount == macChangeCount() else { return nil }
        let lease = generation, mac = macChangeCount()
        task = Task { [weak self] in
            guard let self, let info = try? await read(), !Task.isCancelled,
                  generation == lease, !isKey, identity() == owner, macChangeCount() == mac,
                  let count = info.changeCount, count > baseline.count else { return }
            // Consume even unsupported content; it must not be replayed on every focus event.
            self.baseline = Baseline(identity: owner, count: count, macCount: mac)
            switch VPhoneClipboardTransfer.guestKind(text: info.text, hasImage: info.hasImage) {
            case .text:
                guard let text = info.text, VPhoneClipboardTransfer.fits(text: text) else { return }
            case .image:
                guard let data = info.imageData, VPhoneClipboardTransfer.fits(image: data) else { return }
            case nil: return
            }
            write(info)
            self.baseline = Baseline(identity: owner, count: count, macCount: macChangeCount())
        }
        return task
    }
}

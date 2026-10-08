import Foundation
import VPhoneCore

/// Shortcut operations share the host input queue with automation. Every await
/// is fenced by the focus lease, connection, clipboard revision and Mac counter.
@MainActor
final class VPhoneClipboardShortcutSync {
    private let identity: () -> VPhoneClipboardFocusSync.Identity?
    private let macCount: () -> Int
    private let read: () async throws -> VPhoneControl.ClipboardContent
    private let set: (VPhoneControl.ClipboardContent) async throws -> Void
    private let chord: (UInt32) -> Void
    private let write: (VPhoneControl.ClipboardContent) -> Void
    private var generation = UUID()
    private var syncedMac: (connection: UInt64, count: Int)?

    init(identity: @escaping () -> VPhoneClipboardFocusSync.Identity?, macCount: @escaping () -> Int,
         read: @escaping () async throws -> VPhoneControl.ClipboardContent,
         set: @escaping (VPhoneControl.ClipboardContent) async throws -> Void,
         chord: @escaping (UInt32) -> Void, write: @escaping (VPhoneControl.ClipboardContent) -> Void) {
        self.identity = identity; self.macCount = macCount; self.read = read
        self.set = set; self.chord = chord; self.write = write
    }

    func invalidate() { generation = UUID() }

    func guestCopyWasWrittenToMac() {
        guard let owner = identity() else { syncedMac = nil; return }
        syncedMac = (owner.connection, macCount())
    }

    func copy(cut: Bool) async {
        guard let owner = identity() else { return }
        let lease = generation, mac = macCount()
        let before = try? await read()
        guard valid(lease, owner, mac) else { return }
        chord(cut ? 0x1B : 0x06)
        guard let count = before?.changeCount, count >= 0 else { return }
        for _ in 0..<20 {
            guard valid(lease, owner, mac), !Task.isCancelled else { return }
            guard let value = try? await read(), valid(lease, owner, mac) else { return }
            if let changed = value.changeCount, changed > count {
                guard supported(value) else { return }
                write(value)
                guestCopyWasWrittenToMac()
                return
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    func paste(_ payload: VPhoneControl.ClipboardContent) async {
        guard let owner = identity(), supported(payload) else { return }
        let lease = generation, mac = macCount()
        // A later guest copy must survive pasting an unchanged Mac clipboard.
        if syncedMac?.connection == owner.connection, syncedMac?.count == mac {
            guard valid(lease, owner, mac) else { return }
            chord(0x19)
            return
        }
        do { try await set(payload) } catch { return }
        guard !Task.isCancelled, generation == lease, macCount() == mac,
              let current = identity(), current.connection == owner.connection,
              current.revision == owner.revision &+ 1 else { return }
        syncedMac = (owner.connection, mac)
        chord(0x19)
    }

    private func valid(_ lease: UUID, _ owner: VPhoneClipboardFocusSync.Identity, _ mac: Int) -> Bool {
        !Task.isCancelled && generation == lease && identity() == owner && macCount() == mac
    }

    private func supported(_ value: VPhoneControl.ClipboardContent) -> Bool {
        switch VPhoneClipboardTransfer.guestKind(text: value.text, hasImage: value.hasImage) {
        case .text: return value.text.map(VPhoneClipboardTransfer.fits(text:)) ?? false
        case .image: return value.imageData.map(VPhoneClipboardTransfer.fits(image:)) ?? false
        case nil: return false
        }
    }
}

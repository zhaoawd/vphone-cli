from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
(r/'tests/VPhoneCLITests/ClipboardShortcutTests.swift').write_text('''import Foundation
import Testing
@testable import vphone_cli

@MainActor
struct ClipboardShortcutTests {
    @Test func copyWritesOnlyNewGuestContentAndPreservesLaterMacChanges() async {
        var identity: VPhoneClipboardFocusSync.Identity? = .init(connection: 1, revision: 0)
        var mac = 10, count = 5, writes = 0, chords = 0
        let coordinator = VPhoneClipboardShortcutSync(identity: { identity }, macCount: { mac },
            read: { .init(text: "new", types: [], hasImage: false, changeCount: count, imageData: nil) },
            set: { _ in }, chord: { _ in count += 1; chords += 1 }, write: { _ in writes += 1; mac += 1 })
        await coordinator.copy(cut: false)
        #expect(writes == 1 && chords == 1)
        identity = nil
        await coordinator.copy(cut: false)
        #expect(writes == 1 && chords == 1)
    }

    @Test func pasteDoesNotSendChordAfterFocusLossOrConnectionReplacement() async throws {
        for change in 0..<2 {
            var identity: VPhoneClipboardFocusSync.Identity? = .init(connection: 1, revision: 0)
            var blocked: CheckedContinuation<Void, Never>?, chords = 0
            let coordinator = VPhoneClipboardShortcutSync(identity: { identity }, macCount: { 10 },
                read: { .init(text: nil, types: [], hasImage: false, changeCount: 1, imageData: nil) },
                set: { _ in await withCheckedContinuation { blocked = $0 } },
                chord: { _ in chords += 1 }, write: { _ in })
            let task = Task { await coordinator.paste(.init(text: "mac", types: [], hasImage: false, changeCount: nil, imageData: nil)) }
            for _ in 0..<100 { if blocked != nil { break }; await Task.yield() }
            let continuation = try #require(blocked)
            if change == 0 { coordinator.invalidate() }
            else { identity = .init(connection: 2, revision: 1) }
            continuation.resume(); await task.value
            #expect(chords == 0)
        }
    }
}
''')
(r/'sources/vphone-cli/VPhoneClipboardShortcutSync.swift').write_text('''import Foundation
@MainActor
final class VPhoneClipboardShortcutSync {
    init(identity: @escaping () -> VPhoneClipboardFocusSync.Identity?, macCount: @escaping () -> Int,
         read: @escaping () async throws -> VPhoneControl.ClipboardContent,
         set: @escaping (VPhoneControl.ClipboardContent) async throws -> Void,
         chord: @escaping (UInt32) -> Void, write: @escaping (VPhoneControl.ClipboardContent) -> Void) {
        self.set = set
    }
    let set: (VPhoneControl.ClipboardContent) async throws -> Void
    func copy(cut: Bool) async {}
    func paste(_ payload: VPhoneControl.ClipboardContent) async { try? await set(payload) }
    func invalidate() {}
}
''')
p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadBindingPersistence.swift';s=p.read_text().replace('guard try snapshotInventory(destination) == before, snapshotInventory(source) == before','guard try snapshotInventory(destination) == before, try snapshotInventory(source) == before');p.write_text(s)

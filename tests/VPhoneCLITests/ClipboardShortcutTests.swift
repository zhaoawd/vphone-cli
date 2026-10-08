import Foundation
import Testing
@testable import vphone_cli

@MainActor
struct ClipboardShortcutTests {
    @Test func unchangedMacClipboardDoesNotOverwriteSubsequentGuestCopy() async {
        var revision: UInt64 = 0
        var guest = "", sets = 0, chords = 0
        let coordinator = VPhoneClipboardShortcutSync(identity: { .init(connection: 1, revision: revision) }, macCount: { 10 },
            read: { .init(text: guest, types: [], hasImage: false, changeCount: 1, imageData: nil) },
            set: { value in guest = value.text ?? ""; sets += 1; revision += 1 },
            chord: { _ in chords += 1 }, write: { _ in })
        let mac = VPhoneControl.ClipboardContent(text: "earlier Mac copy", types: [], hasImage: false, changeCount: nil, imageData: nil)
        await coordinator.paste(mac)
        guest = "later guest touch copy"
        await coordinator.paste(mac)
        #expect(guest == "later guest touch copy")
        #expect(sets == 1)
        #expect(chords == 2)
    }

    @Test func changedMacClipboardAndNewConnectionStillSendPayload() async {
        var connection: UInt64 = 1, revision: UInt64 = 0
        var mac = 10, sets = 0, chords = 0
        let coordinator = VPhoneClipboardShortcutSync(identity: { .init(connection: connection, revision: revision) }, macCount: { mac },
            read: { .init(text: nil, types: [], hasImage: false, changeCount: 1, imageData: nil) },
            set: { _ in sets += 1; revision += 1 }, chord: { _ in chords += 1 }, write: { _ in })
        let payload = VPhoneControl.ClipboardContent(text: "Mac copy", types: [], hasImage: false, changeCount: nil, imageData: nil)
        await coordinator.paste(payload)
        mac = 11
        await coordinator.paste(payload)
        connection = 2; revision = 0
        await coordinator.paste(payload)
        #expect(sets == 3 && chords == 3)
    }

    @Test func focusCopyWrittenToMacDoesNotGetSentBackOnPaste() async {
        var revision: UInt64 = 0, sets = 0, chords = 0
        let coordinator = VPhoneClipboardShortcutSync(identity: { .init(connection: 1, revision: revision) }, macCount: { 10 },
            read: { .init(text: nil, types: [], hasImage: false, changeCount: 1, imageData: nil) },
            set: { _ in sets += 1; revision += 1 }, chord: { _ in chords += 1 }, write: { _ in })
        coordinator.guestCopyWasWrittenToMac()
        await coordinator.paste(.init(text: "Guest copy now on Mac", types: [], hasImage: false, changeCount: nil, imageData: nil))
        #expect(sets == 0 && chords == 1)
    }

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
    @Test func successfulPasteSendsExactlyOneChordAfterOwnClipboardRevision() async {
        var identity = VPhoneClipboardFocusSync.Identity(connection: 1, revision: 0)
        var chords: [UInt32] = []
        let coordinator = VPhoneClipboardShortcutSync(identity: { identity }, macCount: { 10 },
            read: { .init(text: nil, types: [], hasImage: false, changeCount: 1, imageData: nil) },
            set: { _ in identity = .init(connection: 1, revision: 1) },
            chord: { chords.append($0) }, write: { _ in })
        await coordinator.paste(.init(text: "mac", types: [], hasImage: false, changeCount: nil, imageData: nil))
        #expect(chords == [0x19])
    }

    @Test func macChangeDuringCopyDoesNotWriteGuestPlainText() async {
        var mac = 10, count = 5, writes = 0
        let coordinator = VPhoneClipboardShortcutSync(identity: { .init(connection: 1, revision: 0) }, macCount: { mac },
            read: { .init(text: "guest", types: [], hasImage: false, changeCount: count, imageData: nil) },
            set: { _ in }, chord: { _ in count += 1; mac += 1 }, write: { _ in writes += 1 })
        await coordinator.copy(cut: false)
        #expect(writes == 0)
    }

    @Test func oldGuestWithoutCountStillReceivesCopyKeyWithoutOverwritingMac() async {
        var chords = 0, writes = 0
        let coordinator = VPhoneClipboardShortcutSync(identity: { .init(connection: 1, revision: 0) }, macCount: { 10 },
            read: { .init(text: "old", types: [], hasImage: false, changeCount: nil, imageData: nil) },
            set: { _ in }, chord: { _ in chords += 1 }, write: { _ in writes += 1 })
        await coordinator.copy(cut: false)
        #expect(chords == 1)
        #expect(writes == 0)
    }

}

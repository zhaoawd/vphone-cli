import Foundation
import Testing
@testable import vphone_cli

@MainActor
private final class FocusClipboardFixture {
    var session: UInt64? = 1
    var revision: UInt64 = 0
    var mac = 10
    var count: Int? = 5
    var writes: [VPhoneControl.ClipboardContent] = []
    var blocked: CheckedContinuation<VPhoneControl.ClipboardContent, any Error>?
    var shouldBlock = false
    func content(_ text: String = "guest") -> VPhoneControl.ClipboardContent {
        .init(text: text, types: [], hasImage: false, changeCount: count, imageData: nil)
    }
    lazy var sync = VPhoneClipboardFocusSync(
        identity: { [self] in session.map { .init(connection: $0, revision: revision) } },
        read: { [self] in
            if shouldBlock { return try await withCheckedThrowingContinuation { blocked = $0 } }
            return content()
        }, macChangeCount: { [self] in mac },
        write: { [self] value in writes.append(value); mac += 1 })
}

@MainActor
struct ClipboardFocusTests {
    @Test func touchCopyNeedsCountAfterFocusBaselineAndDoesNotReplay() async {
        let f = FocusClipboardFixture()
        await f.sync.focusChanged(key: true)?.value
        await f.sync.focusChanged(key: false)?.value
        #expect(f.writes.isEmpty)
        await f.sync.focusChanged(key: true)?.value
        f.count = 6
        await f.sync.focusChanged(key: false)?.value
        #expect(f.writes.count == 1)
        await f.sync.focusChanged(key: false)?.value
        #expect(f.writes.count == 1)
    }

    @Test func unknownOrResetGuestCountAndNewMacRichTextArePreserved() async {
        for next: Int? in [nil, 4] {
            let f = FocusClipboardFixture()
            await f.sync.focusChanged(key: true)?.value
            f.count = next
            await f.sync.focusChanged(key: false)?.value
            #expect(f.writes.isEmpty)
        }
        let f = FocusClipboardFixture()
        await f.sync.focusChanged(key: true)?.value
        f.count = 6; f.mac += 1
        await f.sync.focusChanged(key: false)?.value
        #expect(f.writes.isEmpty)
    }

    @Test func automationMutationUsesNewBaselineInsteadOfReturningPlainText() async {
        let f = FocusClipboardFixture()
        await f.sync.focusChanged(key: true)?.value
        f.revision += 1; f.count = 6
        await f.sync.clipboardMutated()?.value
        await f.sync.focusChanged(key: false)?.value
        #expect(f.writes.isEmpty)
        await f.sync.focusChanged(key: true)?.value
        f.count = 7
        await f.sync.focusChanged(key: false)?.value
        #expect(f.writes.count == 1)
    }

    @Test func lateReadCannotReplaceMacAfterRefocusReconnectMutationOrMacChange() async throws {
        for change in 0..<4 {
            let f = FocusClipboardFixture()
            await f.sync.focusChanged(key: true)?.value
            f.count = 6; f.shouldBlock = true
            let task = f.sync.focusChanged(key: false)
            for _ in 0..<100 {
                if f.blocked != nil { break }
                await Task.yield()
            }
            let blocked = try #require(f.blocked)
            f.shouldBlock = false
            switch change {
            case 0: _ = f.sync.focusChanged(key: true)
            case 1: f.session = 2; f.sync.connectionChanged()
            case 2: f.revision += 1
            default: f.mac += 1
            }
            f.shouldBlock = false
            blocked.resume(returning: f.content())
            f.blocked = nil
            await task?.value
            #expect(f.writes.isEmpty)
            f.sync.stop()
        }
    }

    @Test func stopAndMissingCapabilityDoNotWrite() async {
        let f = FocusClipboardFixture()
        await f.sync.focusChanged(key: true)?.value
        f.session = nil; f.sync.connectionChanged(); f.count = 6
        await f.sync.focusChanged(key: false)?.value
        #expect(f.writes.isEmpty)
        f.sync.stop()
    }
}

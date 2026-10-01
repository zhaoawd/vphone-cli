import Foundation
import Testing
@testable import VPhoneLaunchpadKit

// MARK: - Panel queue (upstream ded81cb)

@MainActor
struct PanelQueueTests {
    @Test func presentingWithNothingOnScreenOpensAtOnce() {
        let panels = VPhoneLaunchpadPanelQueue()
        panels.present(.hostSetup)
        #expect(panels.current == .hostSetup)
        #expect(panels.queued == nil)
        // The same panel again changes nothing.
        panels.present(.hostSetup)
        #expect(panels.current == .hostSetup)
        #expect(panels.queued == nil)
    }

    @Test func nextPanelOpensOnTheNextMainActorTurnAfterDismiss() async throws {
        let panels = VPhoneLaunchpadPanelQueue()
        panels.present(.hostSetup)

        // Another panel closes the current sheet first and waits.
        panels.present(.coreBundle)
        #expect(panels.current == nil)
        #expect(panels.queued == .coreBundle)

        // onDismiss runs in the update that cleared the item: the next panel
        // must not be set in that same turn.
        panels.didDismiss()
        #expect(panels.current == nil)
        #expect(panels.queued == nil)
        let handoff = try #require(panels.handoff)

        await handoff.value
        #expect(panels.current == .coreBundle)
        #expect(panels.queued == nil)
    }

    @Test func dismissWithNothingQueuedLeavesTheSheetClosed() async {
        let panels = VPhoneLaunchpadPanelQueue()
        panels.present(.coreBundle)
        panels.current = nil // the user closed the sheet
        panels.didDismiss()
        #expect(panels.handoff == nil)
        await Task.yield()
        #expect(panels.current == nil)
    }

    @Test func panelsOpenInTheOrderRequested() async throws {
        let panels = VPhoneLaunchpadPanelQueue()
        var shown: [VPhoneLaunchpadPanel] = []
        for next in [VPhoneLaunchpadPanel.hostSetup, .coreBundle, .hostSetup] {
            panels.present(next)
            if panels.current == nil {
                panels.didDismiss()
                let handoff = try #require(panels.handoff)
                await handoff.value
            }
            shown.append(try #require(panels.current))
        }
        #expect(shown == [.hostSetup, .coreBundle, .hostSetup])
    }
}

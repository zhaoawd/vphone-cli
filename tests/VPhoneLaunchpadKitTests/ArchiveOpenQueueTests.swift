import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
struct ArchiveOpenQueueTests {
    @Test func coldOpenPreservesSelectionsUntilVerifiedImporterIsAttached() async throws {
        let queue = VPhoneLaunchpadArchiveOpenQueue()
        let first = ["/归档 files/a.tzst", "/归档 files/b.TXZ"].map { URL(fileURLWithPath: $0) }
        let second = [URL(fileURLWithPath: "/c.tzst")]
        #expect(queue.enqueue(first))
        #expect(queue.enqueue(second))
        var received: [[URL]] = []
        queue.attach { received.append($0) }
        #expect(await eventually { received.count == 2 })
        #expect(received == [first, second])
        queue.attach { _ in Issue.record("importer must not be replaced") }
        #expect(queue.enqueue([URL(fileURLWithPath: "/later.txz")]))
        #expect(await eventually { received.count == 3 })
    }

    @Test func invalidOpenRejectsWholeSelectionWithoutSubmittingAnyMember() async throws {
        let queue = VPhoneLaunchpadArchiveOpenQueue()
        var calls = 0
        queue.attach { _ in calls += 1 }
        #expect(!queue.enqueue([URL(fileURLWithPath: "/good.tzst"), URL(string: "https://example.invalid/bad.txz")!]))
        #expect(!queue.enqueue([URL(fileURLWithPath: "/file.txt")]))
        await Task.yield()
        #expect(calls == 0)
        #expect(queue.error != nil)
    }
}

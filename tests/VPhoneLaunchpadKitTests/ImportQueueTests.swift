import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
struct ImportQueueTests {
    @Test func concurrentImportsWaitAndRunInArrivalOrder() async throws {
        let standIn = try LaunchpadEditStandIn()
        standIn.touch(".import-block")
        let block = URL(fileURLWithPath: standIn.root).appendingPathComponent(".import-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        let first = Task { await library.importArchive(URL(fileURLWithPath: "/archives/first.tzst")) }
        #expect(await eventually { standIn.edits.count == 1 })
        var secondFinished = false
        let second = Task {
            await library.importArchive(URL(fileURLWithPath: "/archives/second.tzst"))
            secondFinished = true
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!secondFinished)
        #expect(standIn.edits.count == 1)
        try FileManager.default.removeItem(at: block)
        await first.value
        await second.value
        #expect(standIn.edits == [
            "vm import /archives/first.tzst --library-root \(standIn.root)",
            "vm import /archives/second.tzst --library-root \(standIn.root)",
        ])
        #expect(library.globalActivity == nil)
        #expect(library.actionError == nil)
    }

    @Test func cancellingWaitingImportReturnsBeforeActiveImportAndKeepsNext() async throws {
        let standIn = try LaunchpadEditStandIn()
        standIn.touch(".import-block")
        let block = URL(fileURLWithPath: standIn.root).appendingPathComponent(".import-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        let first = Task { await library.importArchive(URL(fileURLWithPath: "/archives/first.tzst")) }
        #expect(await eventually { standIn.edits.count == 1 })
        let cancelled = Task { await library.importArchive(URL(fileURLWithPath: "/archives/cancelled.tzst")) }
        await Task.yield()
        let third = Task { await library.importArchive(URL(fileURLWithPath: "/archives/third.tzst")) }
        cancelled.cancel()
        await cancelled.value
        #expect(library.globalActivity != nil)
        #expect(standIn.edits.count == 1)
        try FileManager.default.removeItem(at: block)
        await first.value
        await third.value
        #expect(standIn.edits.count == 2)
        #expect(standIn.edits.last?.contains("third.tzst") == true)
        #expect(!standIn.edits.contains { $0.contains("cancelled.tzst") })
        #expect(library.actionError == nil)
    }

    @Test func batchPreservesOrderAndFailureStopsItsRemainingItems() async throws {
        let standIn = try LaunchpadEditStandIn()
        let library = await standIn.library()
        await library.importArchives([
            URL(fileURLWithPath: "/archives/中文 first.tzst"),
            URL(fileURLWithPath: "/archives/second.txz"),
            try #require(URL(string: "https://example.invalid/refused.tzst")),
            URL(fileURLWithPath: "/archives/skipped.tzst"),
        ])
        #expect(standIn.edits == [
            "vm import /archives/中文 first.tzst --library-root \(standIn.root)",
            "vm import /archives/second.txz --library-root \(standIn.root)",
        ])
        #expect(library.actionError?.message == "Unable to Import refused.tzst")
        await library.importArchive(URL(fileURLWithPath: "/archives/next-selection.tzst"))
        #expect(standIn.edits.last?.contains("next-selection.tzst") == true)
        #expect(library.globalActivity == nil)
    }

    @Test func cancellingActiveBatchDrainsBeforeNextSelection() async throws {
        let standIn = try LaunchpadEditStandIn()
        standIn.touch(".import-block")
        let root = URL(fileURLWithPath: standIn.root)
        let block = root.appendingPathComponent(".import-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        let first = Task {
            await library.importArchives([URL(fileURLWithPath: "/archives/first.tzst"),
                                          URL(fileURLWithPath: "/archives/skipped.tzst")])
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".import-started").path) })
        let next = Task { await library.importArchive(URL(fileURLWithPath: "/archives/next.tzst")) }
        await Task.yield()
        first.cancel()
        await first.value
        try FileManager.default.removeItem(at: block)
        await next.value
        #expect(standIn.history.entries.map(\.status) == [130, 0])
        #expect(standIn.history.entries.allSatisfy { $0.outputDrained == true })
        #expect(standIn.edits.count == 2)
        #expect(standIn.edits.last?.contains("next.tzst") == true)
        #expect(library.actionError == nil)
    }

    @Test func terminationDoesNotLaunchWaitingImports() async throws {
        let standIn = try LaunchpadEditStandIn()
        standIn.touch(".import-block")
        let root = URL(fileURLWithPath: standIn.root)
        defer { try? FileManager.default.removeItem(at: root.appendingPathComponent(".import-block")) }
        let library = await standIn.library()
        let first = Task { await library.importArchive(URL(fileURLWithPath: "/archives/first.tzst")) }
        #expect(await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".import-started").path) })
        let next = Task { await library.importArchive(URL(fileURLWithPath: "/archives/queued.tzst")) }
        await Task.yield()
        let command = try #require(library.currentCommandLine)
        #expect(command.beginTermination())
        #expect(await command.waitForTermination() == .drained)
        await first.value
        await next.value
        #expect(standIn.edits.count == 1)
        #expect(standIn.history.entries.map(\.status) == [130])
        #expect(library.globalActivity == nil)
    }

    @Test func visibleItemsCanCancelOneWaitingArchiveWithoutDroppingItsSelection() async throws {
        let standIn = try LaunchpadEditStandIn()
        standIn.touch(".import-block")
        let root = URL(fileURLWithPath: standIn.root)
        let block = root.appendingPathComponent(".import-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        let batch = Task {
            await library.importArchives(["first", "cancelled", "third"].map {
                URL(fileURLWithPath: "/archives/\($0).tzst")
            })
        }
        #expect(await eventually { standIn.edits.count == 1 && library.imports.count == 3 })
        #expect(library.imports.map(\.state) == [.running, .waiting, .waiting])
        library.cancelImport(try #require(library.imports.first { $0.archive.lastPathComponent == "cancelled.tzst" }).id)
        #expect(library.imports.map { $0.archive.lastPathComponent } == ["first.tzst", "third.tzst"])
        try FileManager.default.removeItem(at: block)
        await batch.value
        #expect(standIn.edits.count == 2)
        #expect(standIn.edits.last?.contains("third.tzst") == true)
        #expect(library.imports.isEmpty)
    }

    @Test func cancellingEveryItemOfAWaitingSelectionReturnsImmediately() async throws {
        let standIn = try LaunchpadEditStandIn()
        standIn.touch(".import-block")
        let block = URL(fileURLWithPath: standIn.root).appendingPathComponent(".import-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        let first = Task { await library.importArchive(URL(fileURLWithPath: "/archives/first.tzst")) }
        #expect(await eventually { standIn.edits.count == 1 })
        var waitingReturned = false
        let waiting = Task {
            await library.importArchives(["second", "third"].map { URL(fileURLWithPath: "/archives/\($0).tzst") })
            waitingReturned = true
        }
        #expect(await eventually { library.imports.count == 3 })
        for item in library.imports where item.state == .waiting { library.cancelImport(item.id) }
        #expect(await eventually { waitingReturned })
        #expect(library.imports.count == 1)
        #expect(standIn.edits.count == 1)
        try FileManager.default.removeItem(at: block)
        await first.value
        await waiting.value
        #expect(library.imports.isEmpty)
    }

    @Test func cancellingActiveItemKeepsRowUntilDrainAndRunsNextItem() async throws {
        let standIn = try LaunchpadEditStandIn()
        standIn.touch(".import-block")
        let root = URL(fileURLWithPath: standIn.root)
        let block = root.appendingPathComponent(".import-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        let batch = Task {
            await library.importArchives(["first", "second"].map { URL(fileURLWithPath: "/archives/\($0).tzst") })
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".import-started").path) })
        let id = try #require(library.imports.first).id
        library.cancelImport(id)
        #expect(library.imports.first?.state == .cancelling)
        #expect(library.hasActiveTransfers)
        #expect(await eventually { standIn.edits.count == 2 })
        #expect(standIn.history.entries.first?.status == 130)
        #expect(standIn.history.entries.first?.outputDrained == true)
        try FileManager.default.removeItem(at: block)
        await batch.value
        #expect(library.imports.isEmpty)
        #expect(!library.hasActiveTransfers)
        #expect(library.actionError == nil)
    }

    @Test func terminationCancelsTransfersWithoutStartingPendingItems() async throws {
        let standIn = try LaunchpadEditStandIn()
        standIn.touch(".import-block")
        let root = URL(fileURLWithPath: standIn.root)
        defer { try? FileManager.default.removeItem(at: root.appendingPathComponent(".import-block")) }
        let library = await standIn.library()
        let first = Task { await library.importArchive(URL(fileURLWithPath: "/archives/first.tzst")) }
        #expect(await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".import-started").path) })
        let waiting = Task { await library.importArchive(URL(fileURLWithPath: "/archives/queued.tzst")) }
        #expect(await eventually { library.imports.count == 2 })
        let command = try #require(library.currentCommandLine)
        #expect(VPhoneLaunchpadQuit.decision(library) == .drainCommands)
        #expect(command.beginTermination())
        library.cancelTransfers()
        #expect(library.imports.count == 1)
        #expect(library.imports.first?.state == .cancelling)
        #expect(await command.waitForTermination() == .drained)
        await first.value
        await waiting.value
        #expect(library.imports.isEmpty)
        #expect(!library.hasActiveTransfers)
        #expect(standIn.edits.count == 1)
        #expect(standIn.history.entries.map(\.status) == [130])
        #expect(library.actionError == nil)
    }

    @Test func terminationTimeoutRetainsCancellingImportAndDoesNotRestoreRemovedItems() async throws {
        let standIn = try LaunchpadEditStandIn()
        standIn.touch(".import-block")
        standIn.touch(".import-ignore-int")
        let root = URL(fileURLWithPath: standIn.root)
        let block = root.appendingPathComponent(".import-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        let batch = Task {
            await library.importArchives(["first", "removed"].map { URL(fileURLWithPath: "/archives/\($0).tzst") })
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".import-started").path) })
        let command = try #require(library.currentCommandLine)
        #expect(command.beginTermination())
        library.cancelTransfers()
        #expect(await command.waitForTermination(timeout: .milliseconds(100)) == .timedOut)
        #expect(command.hasActiveCommands)
        #expect(library.imports.count == 1)
        #expect(library.imports.first?.state == .cancelling)
        #expect(standIn.history.entries.first?.status == nil)
        let next = Task { await library.importArchive(URL(fileURLWithPath: "/archives/after-timeout.tzst")) }
        #expect(await eventually { library.imports.count == 2 })
        try FileManager.default.removeItem(at: block)
        await batch.value
        await next.value
        #expect(standIn.edits.count == 2)
        #expect(standIn.edits.last?.contains("after-timeout.tzst") == true)
        #expect(!standIn.edits.contains { $0.contains("removed.tzst") })
        #expect(standIn.history.entries.allSatisfy { $0.outputDrained == true })
        #expect(library.imports.isEmpty)
        #expect(library.actionError == nil)
    }

    @Test func terminationCancelsMixedTransfersAndPreservesPublishedExport() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b"])
        standIn.touch(".import-block")
        standIn.touch(".export-published")
        standIn.touch(".export-block")
        let root = URL(fileURLWithPath: standIn.root)
        defer {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".import-block"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".export-block"))
        }
        let library = await standIn.library()
        let imports = Task {
            await library.importArchives(["first", "queued"].map { URL(fileURLWithPath: "/archives/\($0).tzst") })
        }
        let completed = standIn.temp.url.appendingPathComponent("a.tzst")
        let pending = standIn.temp.url.appendingPathComponent("b.tzst")
        let exports = Task {
            await library.export([(standIn.path("a"), completed), (standIn.path("b"), pending)],
                                 densest: false, includeIPSW: false, replacing: false)
        }
        #expect(await eventually {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".import-started").path)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent(".export-ready").path)
        })
        let command = try #require(library.currentCommandLine)
        #expect(command.beginTermination())
        library.cancelTransfers()
        #expect(await command.waitForTermination() == .drained)
        await imports.value
        await exports.value
        #expect(!library.hasActiveTransfers)
        #expect(standIn.edits.count == 2)
        #expect(standIn.history.entries.allSatisfy { $0.status == 130 && $0.outputDrained == true })
        #expect(try String(contentsOf: completed, encoding: .utf8) == "committed archive\n")
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        #expect(library.actionError == nil)
    }
}

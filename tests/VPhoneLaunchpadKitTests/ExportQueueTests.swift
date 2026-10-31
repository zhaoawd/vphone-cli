import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
struct ExportQueueTests {
    @Test func independentSelectionsWaitForTheActiveExport() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b"])
        standIn.touch(".export-block")
        standIn.touch(".export-no-output")
        let block = URL(fileURLWithPath: standIn.root).appendingPathComponent(".export-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        let first = Task {
            await library.export([(standIn.path("a"), standIn.temp.url.appendingPathComponent("a.tzst"))],
                                 densest: false, includeIPSW: false, replacing: false)
        }
        try #require(await eventually { standIn.edits.count == 1 })
        let second = Task {
            await library.export([(standIn.path("b"), standIn.temp.url.appendingPathComponent("b.tzst"))],
                                 densest: false, includeIPSW: false, replacing: false)
        }
        try #require(await eventually { library.exports.count == 2 })
        #expect(library.exports[standIn.path("b")]?.isWaiting == true)
        #expect(standIn.edits.count == 1)
        try FileManager.default.removeItem(at: block)
        await first.value
        await second.value
        #expect(standIn.edits.map { $0.split(separator: " ")[2] } == ["a", "b"])
        #expect(library.exports.isEmpty)
    }

    @Test func cancellingCallerStopsItsActiveAndWaitingExports() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b"])
        standIn.touch(".export-block")
        standIn.touch(".export-no-output")
        let root = URL(fileURLWithPath: standIn.root)
        let block = root.appendingPathComponent(".export-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        let batch = Task {
            await library.export([("a", "a.tzst"), ("b", "b.tzst")].map {
                (standIn.path($0.0), standIn.temp.url.appendingPathComponent($0.1))
            }, densest: false, includeIPSW: false, replacing: false)
        }
        try #require(await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent(".export-ready").path) })
        batch.cancel()
        // Always release the stand-in after the assertion so RED cannot hang.
        #expect(await eventually { standIn.history.entries.first?.status == 130 })
        try FileManager.default.removeItem(at: block)
        await batch.value
        #expect(standIn.edits.count == 1)
        #expect(standIn.history.entries.first?.outputDrained == true)
        #expect(library.exports.isEmpty)
        #expect(library.actionError == nil)
    }

    @Test func cancellingAWaitingSelectionReturnsWhileTheActiveExportContinues() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b", "c"])
        standIn.touch(".export-block")
        standIn.touch(".export-no-output")
        let block = URL(fileURLWithPath: standIn.root).appendingPathComponent(".export-block")
        defer { try? FileManager.default.removeItem(at: block) }
        let library = await standIn.library()
        func export(_ name: String) async {
            await library.export([(standIn.path(name), standIn.temp.url.appendingPathComponent(name + ".tzst"))],
                                 densest: false, includeIPSW: false, replacing: false)
        }
        let active = Task { await export("a") }
        try #require(await eventually { standIn.edits.count == 1 })
        var returned = false
        let cancelled = Task { await export("b"); returned = true }
        try #require(await eventually { library.exports.count == 2 })
        let next = Task { await export("c") }
        try #require(await eventually { library.exports.count == 3 })
        library.cancelExport(standIn.path("b"))
        #expect(await eventually { returned })
        #expect(standIn.edits.count == 1)
        try FileManager.default.removeItem(at: block)
        await active.value
        await cancelled.value
        await next.value
        #expect(standIn.edits.map { $0.split(separator: " ")[2] } == ["a", "c"])
        #expect(library.exports.isEmpty)
    }

}

import Foundation
import Testing
@testable import FirmwarePatcher

struct PatchUndoLogTests {
    let generation = String(repeating: "a", count: 64)
    func record(_ id: String = "p1", offset: Int = 1, before: Data = Data([2]), after: Data = Data([8])) -> PatchRecord {
        PatchRecord(patchID: id, component: "dsc", fileOffset: offset, virtualAddress: 0x180000001,
                    originalBytes: before, patchedBytes: after, description: "test")
    }
    @Test func restoresSelectedBytesAndLeavesOtherPatchInSamePage() throws {
        let log = try VPhonePatchUndoLog(generation: generation, records: [record(), record("p2", offset: 3, before: Data([4]), after: Data([9]))])
        let live = Data([1, 8, 3, 9, 5])
        let result = try log.restoring(live, component: "dsc", patchIDs: ["p1"], generation: generation)
        #expect(result.data == Data([1, 2, 3, 9, 5]))
        #expect(result.records.map(\.patchID) == ["p1"])
        #expect(live == Data([1, 8, 3, 9, 5]))
        let decoded = try JSONDecoder().decode(VPhonePatchUndoLog.self, from: JSONEncoder().encode(log))
        #expect(try decoded.restoring(live, component: "dsc", patchIDs: ["p1"], generation: generation).data == result.data)
    }
    @Test func wrongGenerationLiveBytesOrMissingOriginalCannotAuthorizeUndo() throws {
        let log = try VPhonePatchUndoLog(generation: generation, records: [record()])
        for (data, ids, gen) in [(Data([1, 8, 3]), Set(["p1"]), String(repeating: "b", count: 64)),
                                 (Data([1, 7, 3]), Set(["p1"]), generation),
                                 (Data([1, 8, 3]), Set(["unknown"]), generation)] {
            #expect(throws: (any Error).self) { try log.restoring(data, component: "dsc", patchIDs: ids, generation: gen) }
        }
    }
    @Test func malformedAndOverlappingRecordsRefuseWholeResult() throws {
        let live = Data([1, 8, 3, 4])
        for records in [[record(), record("p2", offset: Int.max)],
                        [record(), record("p2", offset: -1)],
                        [record(), record("p2", offset: 1)],
                        [record(before: Data(), after: Data())],
                        [record(before: Data([2, 3]), after: Data([8]))]] {
            #expect(throws: (any Error).self) {
                let log = try VPhonePatchUndoLog(generation: generation, records: records)
                _ = try log.restoring(live, component: "dsc", patchIDs: Set(records.map(\.patchID)), generation: generation)
            }
            #expect(live == Data([1, 8, 3, 4]))
        }
    }
}

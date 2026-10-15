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

    @Test func staleRetainedPatchRefusesWholeComponent() throws {
        let log = try VPhonePatchUndoLog(generation: generation, records: [record(), record("p2", offset: 3, before: Data([4]), after: Data([9]))])
        #expect(throws: VPhonePatchUndoLog.Refusal.currentBytesMismatch) {
            try log.restoring(Data([1, 8, 3, 7, 5]), component: "dsc", patchIDs: ["p1"], generation: generation)
        }
    }

    @Test func noOpRecordCannotEstablishFirstOriginal() throws {
        let log = try VPhonePatchUndoLog(generation: generation, records: [record(before: Data([8]), after: Data([8]))])
        #expect(throws: VPhonePatchUndoLog.Refusal.notRevertible) {
            try log.restoring(Data([1, 8, 3]), component: "dsc", patchIDs: ["p1"], generation: generation)
        }
    }
}

extension PatchUndoLogTests {
    @Test func repeatedApplicationPreservesFirstOriginalAcrossSerialization() throws {
        let log = try VPhonePatchUndoLog(generation: generation, records: [record()])
        let live = Data([1, 8, 3])
        let noop = record(before: Data([8]), after: Data([8]))
        let repeated = try log.adding([noop], before: live, after: live, component: "dsc", generation: generation)
        let next = try repeated.adding([record(before: Data([8]), after: Data([9]))], before: live,
            after: Data([1, 9, 3]), component: "dsc", generation: generation)
        let stored = try JSONDecoder().decode(VPhonePatchUndoLog.self, from: JSONEncoder().encode(next))
        #expect(stored.records.first?.originalBytes == Data([2]))
        #expect(try stored.restoring(Data([1, 9, 3]), component: "dsc", patchIDs: ["p1"], generation: generation).data == Data([1, 2, 3]))
        let empty = try VPhonePatchUndoLog(generation: generation, records: [])
        #expect(throws: VPhonePatchUndoLog.Refusal.notRevertible) {
            try empty.adding([noop], before: live, after: live, component: "dsc", generation: generation)
        }
    }

    @Test func producerCannotOverwriteAnotherPatchOrHideChanges() throws {
        let log = try VPhonePatchUndoLog(generation: generation, records: [record()])
        let live = Data([1, 8, 3])
        #expect(throws: VPhonePatchUndoLog.Refusal.overlap) {
            try log.adding([record("other", before: Data([8]), after: Data([9]))], before: live,
                after: Data([1, 9, 3]), component: "dsc", generation: generation)
        }
        #expect(throws: VPhonePatchUndoLog.Refusal.unrecordedChange) {
            try log.adding([record(before: Data([8]), after: Data([9]))], before: live,
                after: Data([1, 9, 4]), component: "dsc", generation: generation)
        }
    }

    @Test func offOnAndSameIDReplacementPreserveRetainedPatch() throws {
        let log = try VPhonePatchUndoLog(generation: generation,
            records: [record(), record("retained", offset: 3, before: Data([4]), after: Data([9]))])
        let live = Data([1, 8, 3, 9, 5])
        let off = try log.restoring(live, component: "DSC", patchIDs: ["p1"], generation: generation)
        let savedOff = try JSONDecoder().decode(VPhonePatchUndoLog.self, from: JSONEncoder().encode(off.undo))
        #expect(savedOff.records.map(\.patchID) == ["retained"])
        let on = try savedOff.adding([record()], before: off.data, after: live, component: "dsc", generation: generation)
        #expect(try on.restoring(live, component: "dsc", patchIDs: ["p1"], generation: generation).data == off.data)
        let replacement = try log.replacing(live, component: "dsc", patchIDs: ["p1"], generation: generation) { input in
            #expect(input == off.data)
            return (Data([1, 7, 3, 9, 5]), [record(after: Data([7]))])
        }
        #expect(live == Data([1, 8, 3, 9, 5]))
        #expect(replacement.touched.count == 2)
        #expect(try replacement.undo.restoring(replacement.data, component: "dsc", patchIDs: ["p1"], generation: generation).data == off.data)
        #expect(try replacement.undo.restoring(replacement.data, component: "dsc", patchIDs: ["p1", "retained"], generation: generation).data == Data([1, 2, 3, 4, 5]))
    }

    @Test func replacementFailureReturnsNoCandidateAndKeepsOriginalLog() throws {
        let log = try VPhonePatchUndoLog(generation: generation, records: [record()])
        let live = Data([1, 8, 3])
        #expect(throws: POSIXError.self) {
            try log.replacing(live, component: "dsc", patchIDs: ["p1"], generation: generation) { _ in throw POSIXError(.EIO) }
        }
        #expect(log.records.first?.originalBytes == Data([2]))
        #expect(try log.restoring(live, component: "dsc", patchIDs: ["p1"], generation: generation).data == Data([1, 2, 3]))
        #expect(throws: VPhonePatchUndoLog.Refusal.notRevertible) {
            try log.replacing(live, component: "dsc", patchIDs: ["p1"], generation: generation) { ($0, []) }
        }
    }

    @Test func implementationShapeNeverTreatsMissingOrMixedEvidenceAsCurrent() throws {
        let id = "dyld-boot-iomfb_force_kern"
        func shaped(_ count: Int, _ offset: Int = 0) -> PatchRecord {
            record(id, offset: offset, before: Data(repeating: 0, count: count), after: Data(repeating: 1, count: count))
        }
        #expect(try VPhonePatchUndoLog(generation: generation, records: []).implementation(of: id, component: "dsc") == .unknown)
        #expect(try VPhonePatchUndoLog(generation: generation, records: [shaped(4)]).implementation(of: id, component: "dsc") == .outdated)
        #expect(try VPhonePatchUndoLog(generation: generation, records: [shaped(16)]).implementation(of: id, component: "dsc") == .current)
        #expect(try VPhonePatchUndoLog(generation: generation, records: [shaped(4), shaped(16, 16)]).implementation(of: id, component: "dsc") == .unknown)
        #expect(try VPhonePatchUndoLog(generation: generation, records: [shaped(8)]).implementation(of: id, component: "dsc") == .unknown)
        let old = try VPhonePatchUndoLog(generation: generation, records: [shaped(4)])
        let live = Data(repeating: 1, count: 4) + Data(repeating: 0, count: 16)
        #expect(throws: VPhonePatchUndoLog.Refusal.outdatedImplementation) {
            try old.replacing(live, component: "dsc", patchIDs: [id], generation: generation) { _ in (live, [shaped(4)]) }
        }
        let next = try old.replacing(live, component: "dsc", patchIDs: [id], generation: generation) { _ in
            (Data(repeating: 1, count: 16) + Data(repeating: 0, count: 4), [shaped(16)])
        }
        #expect(try next.undo.restoring(next.data, component: "dsc", patchIDs: [id], generation: generation).data == Data(repeating: 0, count: 20))
    }
}

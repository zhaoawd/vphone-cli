import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareComponentUndoTests {
    func committed() throws -> FirmwareComponentReceiptTests.Fixture {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let helper = FirmwareReceiptPublicationTests()
        let t = try helper.begin(f)
        try helper.prepare(f, t)
        _ = try t.commit()
        return f
    }

    @Test func committedProducerRecordsProvidePersistedUndoWithoutNewSidecar() throws {
        let f = try committed()
        let snapshot = try FirmwareComponentUndo.load(in: f.vm, component: "avpbooter", generationID: f.generation.id)
        let declaration = try #require(snapshot.receipt.effects.first?.declarationID)
        let restored = try snapshot.restoring(declarations: [declaration])
        #expect(restored.data == Data([0]))
        #expect(try Data(contentsOf: f.file) == Data([1]))
        #expect(restored.records == snapshot.receipt.effects.map(\.record))
        #expect(throws: (any Error).self) {
            try FirmwareComponentUndo.load(in: f.vm, component: "avpbooter", generationID: String(repeating: "b", count: 64))
        }
        #expect(throws: (any Error).self) { try snapshot.restoring(declarations: ["not-recorded"]) }
    }

    @Test(arguments: ["output", "receipt", "report", "generation"])
    func snapshotRevalidatesEvidenceBeforeReturningCandidate(_ fault: String) throws {
        let f = try committed()
        let snapshot = try FirmwareComponentUndo.load(in: f.vm, component: "avpbooter", generationID: f.generation.id)
        let declaration = try #require(snapshot.receipt.effects.first?.declarationID)
        switch fault {
        case "output": try Data([2]).write(to: f.file)
        case "receipt": try Data("broken".utf8).write(to: f.vm.appendingPathComponent(".firmware-component-receipts.json"))
        case "report":
            let history = f.vm.appendingPathComponent(".firmware-history")
            let archive = try #require(FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).first)
            try Data("broken".utf8).write(to: archive.appendingPathComponent("report.json"))
        default:
            let originals = try FirmwareGeneration.originalURLs(in: f.vm, id: f.generation.id)
            let file = try #require(originals.first { $0.lastPathComponent == f.file.lastPathComponent })
            try Data([2]).write(to: file)
        }
        #expect(throws: (any Error).self) { try snapshot.restoring(declarations: [declaration]) }
    }

    @Test func replacementRechecksAfterProducerAndDoesNotPublishPayload() throws {
        let f = try committed()
        let snapshot = try FirmwareComponentUndo.load(in: f.vm, component: "avpbooter", generationID: f.generation.id)
        let effect = try #require(snapshot.receipt.effects.first)
        let old = effect.record
        let result = try snapshot.replacing(declarations: [effect.declarationID]) { input in
            #expect(input == Data([0]))
            return (Data([2]), [PatchRecord(patchID: old.patchID, component: old.component,
                fileOffset: old.fileOffset, virtualAddress: old.virtualAddress, originalBytes: input,
                patchedBytes: Data([2]), description: "new producer")])
        }
        #expect(result.data == Data([2]))
        #expect(try Data(contentsOf: f.file) == Data([1]))
        #expect(result.undo.records.first?.originalBytes == Data([0]))
        #expect(throws: (any Error).self) {
            try snapshot.replacing(declarations: [effect.declarationID]) { input in
                try Data([3]).write(to: f.file)
                return (Data([2]), [PatchRecord(patchID: old.patchID, component: old.component,
                    fileOffset: old.fileOffset, virtualAddress: old.virtualAddress, originalBytes: input,
                    patchedBytes: Data([2]), description: "drifting producer")])
            }
        }
    }

    @Test func missingOrPreparedReceiptDoesNotSupplyUndo() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        #expect(throws: (any Error).self) { try FirmwareComponentUndo.load(in: f.vm, component: "avpbooter", generationID: f.generation.id) }
        let helper = FirmwareReceiptPublicationTests()
        let t = try helper.begin(f)
        try helper.prepare(f, t)
        try Data(contentsOf: t.root.appendingPathComponent("component-receipts.json"))
            .write(to: f.vm.appendingPathComponent(".firmware-component-receipts.json"))
        #expect(throws: (any Error).self) { try FirmwareComponentUndo.load(in: f.vm, component: "avpbooter", generationID: f.generation.id) }
    }
}

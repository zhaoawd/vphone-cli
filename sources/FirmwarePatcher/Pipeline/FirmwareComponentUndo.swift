import Foundation

/// Reversible byte evidence recovered from the existing committed publication.
/// This API prepares payload copies only. Container signing, page attestation,
/// disk publication and activation remain the responsibility of the transaction.
public enum FirmwareComponentUndo {
    public struct Snapshot {
        public let receipt: FirmwareComponentReceipt.Record
        public let undo: VPhonePatchUndoLog
        let directory: URL
        let payload: Data

        fileprivate init(receipt: FirmwareComponentReceipt.Record, directory: URL, payload: Data) throws {
            self.receipt = receipt
            self.directory = directory
            self.payload = payload
            undo = try VPhonePatchUndoLog(generation: receipt.generationID, records: receipt.effects.map(\.record))
            _ = try undo.restoring(payload, component: receipt.component, patchIDs: [], generation: receipt.generationID)
        }

        public func restoring(declarations: Set<String>) throws -> VPhonePatchUndoLog.Restoration {
            let ids = try patchIDs(for: declarations)
            try recheck()
            let result = try undo.restoring(payload, component: receipt.component, patchIDs: ids, generation: receipt.generationID)
            try recheck()
            return result
        }

        public func replacing(declarations: Set<String>,
            apply: (Data) throws -> (data: Data, records: [PatchRecord])) throws -> VPhonePatchUndoLog.Replacement {
            let ids = try patchIDs(for: declarations)
            try recheck()
            let result = try undo.replacing(payload, component: receipt.component, patchIDs: ids,
                                            generation: receipt.generationID, apply: apply)
            try recheck()
            return result
        }

        private func patchIDs(for declarations: Set<String>) throws -> Set<String> {
            let selected = receipt.effects.filter { declarations.contains($0.declarationID) }
            guard !declarations.isEmpty, Set(selected.map(\.declarationID)) == declarations else {
                throw VPhonePatchUndoLog.Refusal.notRevertible
            }
            let ids = Set(selected.map { $0.record.patchID })
            guard receipt.effects.filter({ ids.contains($0.record.patchID) }).allSatisfy({ declarations.contains($0.declarationID) }) else {
                throw VPhonePatchUndoLog.Refusal.notRevertible
            }
            return ids
        }

        fileprivate func recheck() throws {
            guard let records = try FirmwareComponentReceipt.readCommitted(in: directory), records.contains(receipt) else {
                throw FirmwareGeneration.fail("Undo receipt changed since qualification")
            }
        }
    }

    /// A decoded/imported receipt cannot construct this non-Codable snapshot.
    /// Call under the VM operation lock. Each preparation rechecks publication,
    /// generation, all output hashes and exact producer records before returning.
    public static func load(in directory: URL, component: String, generationID: String) throws -> Snapshot {
        guard let records = try FirmwareComponentReceipt.readCommitted(in: directory) else {
            throw VPhonePatchUndoLog.Refusal.notRevertible
        }
        let matches = records.filter { $0.component == component }
        guard matches.count == 1, let record = matches.first,
              record.scope == .generatedFirmware, record.generationID == generationID,
              record.outputs.count == 1, let output = record.outputs.first,
              !["filesystem", "manifest", "devicetree"].contains(component.lowercased()),
              record.effects.allSatisfy({ $0.outputPath == output.path && $0.record.component.lowercased() == component.lowercased() }) else {
            throw VPhonePatchUndoLog.Refusal.notRevertible
        }
        let file = directory.appendingPathComponent(output.path)
        let payload = Data(try IM4PHandler.load(contentsOf: file).payload)
        let snapshot = try Snapshot(receipt: record, directory: directory, payload: payload)
        try snapshot.recheck()
        return snapshot
    }
}

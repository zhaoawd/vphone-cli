import Foundation

/// Content undo using the existing per-patch records. This is an in-memory
/// preparation step; a caller must authenticate originals/generation, re-attest
/// touched code pages, and publish disk/receipt/undo state in one transaction.
public struct VPhonePatchUndoLog: Codable, Sendable {
    public let generation: String
    public let records: [PatchRecord]

    public enum Refusal: Error { case invalidGeneration, notRevertible, invalidRecord, overlap, currentBytesMismatch }
    public struct Restoration: Sendable {
        public let data: Data
        /// The caller uses these byte spans to re-attest the resulting pages.
        public let records: [PatchRecord]
    }

    public init(generation: String, records: [PatchRecord]) throws {
        guard Self.validGeneration(generation) else { throw Refusal.invalidGeneration }
        self.generation = generation
        self.records = records
    }

    /// No supplied bytes are mutated. Validate the whole component, including
    /// overlaps with retained patches, before constructing a restored copy.
    public func restoring(_ live: Data, component: String, patchIDs: Set<String>, generation: String) throws -> Restoration {
        guard Self.validGeneration(self.generation), generation == self.generation else { throw Refusal.invalidGeneration }
        let componentRecords = records.filter { $0.component == component }
        let selected = componentRecords.filter { patchIDs.contains($0.patchID) }
        guard Set(selected.map(\.patchID)) == patchIDs else { throw Refusal.notRevertible }
        var ranges: [Range<Int>] = []
        for record in componentRecords {
            guard !record.patchID.isEmpty, !record.originalBytes.isEmpty,
                  record.originalBytes.count == record.patchedBytes.count,
                  record.fileOffset >= 0, record.fileOffset <= live.count,
                  record.originalBytes.count <= live.count - record.fileOffset else { throw Refusal.invalidRecord }
            let range = record.fileOffset..<(record.fileOffset + record.originalBytes.count)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw Refusal.overlap }
            ranges.append(range)
        }
        let data = Data(live)
        for record in selected {
            let range = record.fileOffset..<(record.fileOffset + record.patchedBytes.count)
            guard data.subdata(in: range) == record.patchedBytes else { throw Refusal.currentBytesMismatch }
        }
        var restored = data
        for record in selected {
            restored.replaceSubrange(record.fileOffset..<(record.fileOffset + record.originalBytes.count), with: record.originalBytes)
        }
        return Restoration(data: restored, records: selected)
    }

    private static func validGeneration(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

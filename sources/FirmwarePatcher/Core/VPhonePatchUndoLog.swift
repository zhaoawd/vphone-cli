import Foundation

/// Content undo using the existing per-patch records. This is an in-memory
/// preparation step; a caller must authenticate originals/generation, re-attest
/// touched code pages, and publish disk/receipt/undo state in one transaction.
public struct VPhonePatchUndoLog: Codable, Sendable {
    public let generation: String
    public let records: [PatchRecord]

    public enum Refusal: Error { case invalidGeneration, notRevertible, invalidRecord, overlap, currentBytesMismatch, unrecordedChange, outdatedImplementation }
    /// Record shape is an observation, not an authentication or byte proof.
    public enum Implementation: Sendable { case outdated, current, unknown }
    public struct Restoration: Sendable {
        public let data: Data
        /// The caller uses these byte spans to re-attest the resulting pages.
        public let records: [PatchRecord]
        public let undo: VPhonePatchUndoLog
    }

    public init(generation: String, records: [PatchRecord]) throws {
        guard Self.validGeneration(generation) else { throw Refusal.invalidGeneration }
        self.generation = generation
        self.records = records
    }

    public func implementation(of patchID: String, component: String) -> Implementation {
        let matches = records.filter { $0.component.lowercased() == component.lowercased() && $0.patchID == patchID }
        guard patchID == "dyld-boot-iomfb_force_kern", !matches.isEmpty,
              matches.allSatisfy({ $0.originalBytes.count == $0.patchedBytes.count }) else { return .unknown }
        if matches.allSatisfy({ $0.originalBytes.count == 4 }) { return .outdated }
        if matches.allSatisfy({ $0.originalBytes.count == 16 }) { return .current }
        return .unknown
    }

    /// No supplied bytes are mutated. Validate the whole component, including
    /// overlaps with retained patches, before constructing a restored copy.
    public func restoring(_ live: Data, component: String, patchIDs: Set<String>, generation: String) throws -> Restoration {
        guard Self.validGeneration(self.generation), generation == self.generation else { throw Refusal.invalidGeneration }
        let componentRecords = records.filter { $0.component.lowercased() == component.lowercased() }
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
        // Retained patches share the component and its re-attested pages. A
        // stale retained effect must not be silently carried into a new log.
        for record in componentRecords {
            let range = record.fileOffset..<(record.fileOffset + record.patchedBytes.count)
            guard data.subdata(in: range) == record.patchedBytes else { throw Refusal.currentBytesMismatch }
        }
        guard selected.allSatisfy({ $0.originalBytes != $0.patchedBytes }) else { throw Refusal.notRevertible }
        var restored = data
        for record in selected {
            restored.replaceSubrange(record.fileOffset..<(record.fileOffset + record.originalBytes.count), with: record.originalBytes)
        }
        let retained = try Self(generation: self.generation,
            records: records.filter { $0.component.lowercased() != component.lowercased() || !patchIDs.contains($0.patchID) })
        return Restoration(data: restored, records: selected, undo: retained)
    }

    /// Merge actual producer records, preserving the first original on an
    /// idempotent or repeated application. Callers authenticate this log first.
    /// The exact before/after comparison forbids unrecorded payload writes.
    public func adding(_ changes: [PatchRecord], before: Data, after: Data,
                       component: String, generation: String) throws -> Self {
        _ = try restoring(before, component: component, patchIDs: [], generation: generation)
        guard before.count == after.count else { throw Refusal.invalidRecord }
        var result = records
        var reconstructed = Data(before)
        var ranges: [Range<Int>] = []
        for change in changes {
            guard change.component.lowercased() == component.lowercased(), !change.patchID.isEmpty,
                  !change.originalBytes.isEmpty, change.originalBytes.count == change.patchedBytes.count,
                  change.fileOffset >= 0, change.fileOffset <= before.count,
                  change.originalBytes.count <= before.count - change.fileOffset else { throw Refusal.invalidRecord }
            let range = change.fileOffset..<(change.fileOffset + change.originalBytes.count)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw Refusal.overlap }
            ranges.append(range)
            guard Data(before).subdata(in: range) == change.originalBytes,
                  Data(after).subdata(in: range) == change.patchedBytes else { throw Refusal.currentBytesMismatch }
            let overlaps = result.indices.filter {
                let record = result[$0]
                return record.component.lowercased() == component.lowercased() && (record.fileOffset..<(record.fileOffset + record.originalBytes.count)).overlaps(range)
            }
            if let index = overlaps.first {
                let old = result[index]
                guard overlaps.count == 1, old.patchID == change.patchID, old.fileOffset == change.fileOffset,
                      old.originalBytes.count == change.originalBytes.count,
                      old.virtualAddress == change.virtualAddress else { throw Refusal.overlap }
                result[index] = PatchRecord(patchID: old.patchID, component: old.component, fileOffset: old.fileOffset,
                    virtualAddress: old.virtualAddress, originalBytes: old.originalBytes, patchedBytes: change.patchedBytes,
                    beforeDisasm: old.beforeDisasm, afterDisasm: change.afterDisasm, description: change.patchDescription)
            } else {
                guard change.originalBytes != change.patchedBytes else { throw Refusal.notRevertible }
                result.append(change)
            }
            reconstructed.replaceSubrange(range, with: change.patchedBytes)
        }
        guard reconstructed == Data(after) else { throw Refusal.unrecordedChange }
        return try Self(generation: self.generation, records: result)
    }

    public struct Replacement: Sendable {
        public let data: Data
        public let undo: VPhonePatchUndoLog
        /// Includes both reverted and newly written spans for page re-attestation.
        public let touched: [PatchRecord]
    }

    /// Runs the producer against a restored copy. A thrown error returns no
    /// candidate; the live payload and the authenticated original log stay intact.
    public func replacing(_ live: Data, component: String, patchIDs: Set<String>, generation: String,
                          apply: (Data) throws -> (data: Data, records: [PatchRecord])) throws -> Replacement {
        guard !patchIDs.isEmpty else { throw Refusal.notRevertible }
        let restored = try restoring(live, component: component, patchIDs: patchIDs, generation: generation)
        let candidate = try apply(restored.data)
        guard Set(candidate.records.map(\.patchID)) == patchIDs else { throw Refusal.notRevertible }
        let merged = try restored.undo.adding(candidate.records, before: restored.data, after: candidate.data,
                                        component: component, generation: generation)
        if patchIDs.contains("dyld-boot-iomfb_force_kern"),
           merged.implementation(of: "dyld-boot-iomfb_force_kern", component: component) != .current {
            throw Refusal.outdatedImplementation
        }
        return Replacement(data: candidate.data, undo: merged, touched: restored.records + candidate.records)
    }

    private static func validGeneration(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

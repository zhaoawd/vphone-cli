import Foundation
import Darwin
import VPhoneCore

/// Per-record output evidence. Selection, generated artifacts and installed
/// components have distinct states; decoding this record grants no authority.
public enum FirmwareComponentReceipt {
    public enum State: String, Codable, Sendable { case desired, planned, generated, committed, activated, accepted }
    public enum Scope: String, Codable, Sendable { case generatedFirmware, installedComponent }
    public struct Output: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
    }
    public struct Effect: Codable, Equatable, Sendable {
        public let declarationID: String
        public let outputPath: String
        public let record: PatchRecord
    }
    public struct Record: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let component: String
        public let scope: Scope
        public internal(set) var state: State
        public let generationID: String
        public let planSHA256: String
        public let desiredSHA256: String
        public let outputs: [Output]
        public let effects: [Effect]
    }

    /// Captures published files. Transaction staging uses the explicit-root
    /// overload so a temporary path cannot silently be interpreted as installed.
    public static func capture(component: String, plan: VariantPlanResolver.VariantPlan,
                               generation: FirmwareGeneration.Manifest, records: [PatchRecord], outputs: [URL]) throws -> Record {
        guard let first = outputs.first else { throw failure("missing component output") }
        var directory = first.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.plist").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { throw failure("output has no VM qualification") }
            directory = parent
        }
        return try capture(component: component, plan: plan, generation: generation, records: records,
                           outputs: outputs, root: directory, machine: directory)
    }

    static func capture(component: String, plan: VariantPlanResolver.VariantPlan,
                        generation: FirmwareGeneration.Manifest, records: [PatchRecord], outputs: [URL],
                        root: URL, machine: URL) throws -> Record {
        guard !records.isEmpty, outputs.count == 1 else {
            throw failure("component requires actual records and one unambiguous payload output")
        }
        guard try FirmwareGeneration.loadVerified(in: machine, id: generation.id) == generation,
              case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: machine),
              desired.plan == plan, desired.generationID == generation.id else {
            throw failure("generation/desired qualification differs")
        }
        return try captureQualified(component: component, plan: plan, generation: generation,
            desiredSHA256: desired.sha256, records: records, outputs: outputs, root: root)
    }

    private static func captureQualified(component: String, plan: VariantPlanResolver.VariantPlan,
        generation: FirmwareGeneration.Manifest, desiredSHA256: String, records: [PatchRecord],
        outputs: [URL], root: URL) throws -> Record {
        guard !records.isEmpty, outputs.count == 1 else {
            throw failure("component requires actual records and one unambiguous payload output")
        }
        let path = try relative(outputs[0], in: root)
        let digest = try FirmwareGeneration.fileSHA256(outputs[0])
        let payload = Data(try IM4PHandler.load(contentsOf: outputs[0]).payload)
        if component.lowercased() == "filesystem" || component.lowercased() == "manifest" {
            try FirmwarePipeline.validateManifest(in: outputs[0].deletingLastPathComponent())
        }
        let effects = try records.map { record -> Effect in
            guard record.component.lowercased() == component.lowercased() else { throw failure("record component differs") }
            let owners = plan.selected.filter { ($0.recordRules ?? []).contains { $0.matches(record) } }
            guard owners.count == 1, let owner = owners.first,
                  owner.swiftSteps.contains(where: { $0.hasPrefix(component.lowercased() + ".") }) else {
                throw failure("record has no unique selected component declaration")
            }
            try verifyEffect(record, payload: payload)
            return Effect(declarationID: owner.id, outputPath: path, record: record)
        }
        let proven = Set(effects.map(\.declarationID))
        for entry in plan.selected where entry.required && entry.swiftSteps.contains(where: { $0.hasPrefix(component.lowercased() + ".") }) {
            guard proven.contains(entry.id) else { throw failure("missing required component record: \(entry.id)") }
        }
        guard try FirmwareGeneration.fileSHA256(outputs[0]) == digest else { throw failure("output changed during readback") }
        return Record(schemaVersion: 1, component: component, scope: .generatedFirmware, state: .generated,
                      generationID: generation.id, planSHA256: try FirmwareGeneration.planDigest(plan),
                      desiredSHA256: desiredSHA256, outputs: [Output(path: path, sha256: digest)], effects: effects)
    }

    public static func verify(_ record: Record, in directory: URL) throws {
        try verify(record, root: directory, machine: directory)
    }

    static func verify(_ record: Record, root: URL, machine: URL) throws {
        guard record.schemaVersion == 1, record.scope == .generatedFirmware,
              record.state == .generated || record.state == .committed,
              case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: machine),
              try desired.sha256 == record.desiredSHA256, desired.planSHA256 == record.planSHA256,
              desired.generationID == record.generationID else { throw failure("receipt qualification differs") }
        let generation = try FirmwareGeneration.loadVerified(in: machine, id: record.generationID)
        let outputs = try record.outputs.map { output -> URL in
            let url = root.appendingPathComponent(output.path)
            guard try relative(url, in: root) == output.path,
                  try FirmwareGeneration.fileSHA256(url) == output.sha256 else { throw failure("published output differs") }
            return url
        }
        var rebuilt = try capture(component: record.component, plan: desired.plan, generation: generation,
                                  records: record.effects.map(\.record), outputs: outputs, root: root, machine: machine)
        rebuilt.state = record.state
        guard rebuilt == record else { throw failure("receipt effect or ownership differs") }
    }

    /// Committed history is the sole publication authority. Returned records
    /// remain data, not permission to install, activate, or change origins.
    public static func readCommitted(in directory: URL) throws -> [Record]? {
        try VPhoneMachineBinding.withCommittedOriginsRead(directory) {
            let file = directory.appendingPathComponent(FirmwareTransaction.ComponentPublication.filename)
            var info = stat()
            if lstat(file.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw failure("receipt is unreadable")
            }
            let bytes = try VPhoneCreateDigest.strictFileData(file, maximumBytes: 64 << 20)
            let publication = try JSONDecoder().decode(FirmwareTransaction.ComponentPublication.self, from: bytes)
            guard publication.schemaVersion == 1, UUID(uuidString: publication.transactionID) != nil else { throw failure("unsupported publication") }
            let history = directory.appendingPathComponent(".firmware-history")
            try FirmwareGeneration.ensureDirectory(history, create: false)
            let archive = history.appendingPathComponent(publication.transactionID)
            try FirmwareGeneration.ensureDirectory(archive, create: false)
            let journal = try FirmwareTransaction.readJournal(at: archive.appendingPathComponent("journal.json"))
            let digest = VPhoneCreateDigest.sha256(bytes)
            guard journal.id == publication.transactionID, journal.phase == .committed,
                  journal.componentReceiptsSHA256 == digest,
                  journal.metadata?.first(where: { $0.name == FirmwareTransaction.ComponentPublication.filename })?.output == digest,
                  try FirmwareGeneration.fileSHA256(archive.appendingPathComponent("component-receipts.json")) == digest else {
                throw failure("receipt has no matching committed journal")
            }
            try verifySavedReport(publication, journal: journal, archive: archive)
            guard let plan = journal.plan, let generationID = journal.options["generationID"],
                  let desiredSHA256 = journal.options["desiredSHA256"], FirmwareGeneration.validDigest(desiredSHA256),
                  let binding = journal.planBinding, binding.payload.generationID == generationID else {
                throw failure("receipt has no saved plan qualification")
            }
            try binding.validate(journal: journal, directory: directory, currentCatalog: false)
            let generation = try FirmwareGeneration.loadVerified(in: directory, id: generationID)
            // Applied evidence belongs to the plan that produced it. A later
            // desired selection must neither erase this evidence nor relabel it.
            for record in publication.records {
                guard record.schemaVersion == 1, record.scope == .generatedFirmware, record.state == .committed,
                      record.generationID == generationID, record.desiredSHA256 == desiredSHA256 else {
                    throw failure("archived receipt qualification differs")
                }
                var rebuilt = try captureQualified(component: record.component, plan: plan, generation: generation,
                    desiredSHA256: desiredSHA256, records: record.effects.map(\.record),
                    outputs: record.outputs.map { directory.appendingPathComponent($0.path) }, root: directory)
                rebuilt.state = .committed
                guard rebuilt == record else { throw failure("archived receipt effect or ownership differs") }
            }
            if let installed = publication.installed {
                guard installed.schemaVersion == 1, installed.scope == .installedComponent, installed.state == .committed,
                      installed.generationID == generationID, installed.desiredSHA256 == desiredSHA256,
                      installed.planSHA256 == (try FirmwareGeneration.planDigest(plan)),
                      let proof = publication.originProofSHA256, publication.originLayer != nil,
                      try FirmwareGeneration.fileSHA256(archive.appendingPathComponent("installed-component-proof.json")) == proof else {
                    throw failure("installed receipt has no committed proof")
                }
                for output in installed.outputs {
                    let url = directory.appendingPathComponent(output.path)
                    guard try relative(url, in: directory) == output.path,
                          try FirmwareGeneration.fileSHA256(url) == output.sha256 else { throw failure("installed receipt output differs") }
                }
            }
            guard try FirmwareGeneration.fileSHA256(file) == digest,
                  try FirmwareGeneration.fileSHA256(archive.appendingPathComponent("report.json")) == journal.reportSHA256,
                  try FirmwareTransaction.readJournal(at: archive.appendingPathComponent("journal.json")) == journal else {
                throw failure("receipt or committed evidence changed during read")
            }
            return publication.records + (publication.installed.map { [$0] } ?? [])
        }
    }

    private static func verifySavedReport(_ publication: FirmwareTransaction.ComponentPublication,
        journal: FirmwareTransaction.Journal, archive: URL) throws {
        guard let expected = journal.reportSHA256 else { throw failure("receipt has no saved report") }
        let bytes = try VPhoneCreateDigest.strictFileData(archive.appendingPathComponent("report.json"), maximumBytes: 64 << 20)
        guard VPhoneCreateDigest.sha256(bytes) == expected else { throw failure("saved receipt report differs") }
        let report = try JSONDecoder().decode(PatchRunReport.self, from: bytes)
        let evidence = journal.kernelOnly == true ? publication.installed.map { [$0] } ?? [] : publication.records
        guard !report.allRecords.isEmpty, report.failedRequired.isEmpty,
              (!publication.records.isEmpty || journal.kernelOnly == true),
              journal.kernelOnly != true || (publication.records.isEmpty && publication.filesystem == nil && publication.installed != nil),
              (publication.filesystem != nil) == publication.records.contains(where: { $0.component.lowercased() == "filesystem" }),
              (publication.filesystem != nil) == (publication.filesystemProofSHA256 != nil),
              (publication.installed != nil) == (publication.originLayer != nil),
              (publication.installed != nil) == (publication.originProofSHA256 != nil),
              Set(evidence.map { $0.component.lowercased() }).count == evidence.count,
              Dictionary(grouping: report.allRecords, by: { $0.component.lowercased() }) ==
                Dictionary(uniqueKeysWithValues: evidence.map { ($0.component.lowercased(), $0.effects.map(\.record)) }) else {
            throw failure("receipt does not cover exact saved producer records")
        }
    }

    static func verifyEffect(_ record: PatchRecord, payload: Data) throws {
        if record.component.lowercased() == "devicetree" {
            try DeviceTreePatcher.verifyEffect(record, payload: payload)
            return
        }
        if record.patchID == "filesystem.cryptex.merge" || record.patchID == "manifest.hash" {
            let before = try PropertyListSerialization.propertyList(from: record.originalBytes, format: nil)
            let after = try PropertyListSerialization.propertyList(from: record.patchedBytes, format: nil)
            let final = try PropertyListSerialization.propertyList(from: payload, format: nil)
            try verifyProjection(before: before, after: after, final: final)
            return
        }
        guard record.fileOffset >= 0, !record.patchedBytes.isEmpty,
              record.fileOffset <= payload.count,
              record.patchedBytes.count <= payload.count - record.fileOffset else {
            throw failure("required effect absent from final output: \(record.patchID)")
        }
        // Patch records use payload-relative offsets; DER payload views can
        // retain a nonzero Data startIndex from their enclosing container.
        let start = payload.index(payload.startIndex, offsetBy: record.fileOffset)
        let end = payload.index(start, offsetBy: record.patchedBytes.count)
        guard payload[start..<end] == record.patchedBytes else {
            throw failure("required effect absent from final output: \(record.patchID)")
        }
    }

    /// Compares only keys changed by this operation. Arrays of equal size
    /// retain their indices, including BuildIdentities[0]. Later disjoint digest
    /// changes therefore cannot hide a missing earlier manifest path change.
    private static func verifyProjection(before: Any?, after: Any?, final: Any?) throws {
        if let old = before as? NSObject, let new = after as? NSObject, old.isEqual(new) { return }
        if let old = before as? [String: Any], let new = after as? [String: Any] {
            guard let actual = final as? [String: Any] else { throw failure("required plist dictionary missing") }
            for key in Set(old.keys).union(new.keys) {
                try verifyProjection(before: old[key], after: new[key], final: actual[key])
            }
        } else if let old = before as? [Any], let new = after as? [Any], old.count == new.count {
            guard let actual = final as? [Any], actual.count == new.count else { throw failure("required plist array differs") }
            for index in new.indices { try verifyProjection(before: old[index], after: new[index], final: actual[index]) }
        } else if after == nil {
            guard final == nil else { throw failure("required plist deletion was reversed") }
        } else {
            guard let expected = after as? NSObject, let actual = final as? NSObject, expected.isEqual(actual) else {
                throw failure("required plist effect was overwritten")
            }
        }
    }

    static func relative(_ url: URL, in directory: URL) throws -> String {
        let root = directory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root), url.path == url.standardizedFileURL.path else { throw failure("output escapes publication root") }
        let relative = String(path.dropFirst(root.count))
        guard !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw failure("invalid output path") }
        var parent = url.deletingLastPathComponent()
        while parent.path != directory.standardizedFileURL.path {
            try FirmwareGeneration.ensureDirectory(parent, create: false)
            parent = parent.deletingLastPathComponent()
        }
        try FirmwareGeneration.ensureDirectory(directory, create: false)
        return relative
    }
    private static func failure(_ message: String) -> FirmwareGeneration.Failure {
        FirmwareGeneration.fail("Component receipt: " + message)
    }
}

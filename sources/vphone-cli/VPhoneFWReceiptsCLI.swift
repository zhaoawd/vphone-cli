import ArgumentParser
import Foundation
import FirmwarePatcher
import VPhoneCore

struct VPhoneFWReceiptsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "receipts",
        abstract: "Read committed component evidence or preview byte undo without changing firmware")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(help: "Emit JSON") var json = false
    @Option(help: "Component to preview undo for; generated firmware only") var undoComponent: String?
    @Option(help: "Expected verified generation ID for undo preview") var generation: String?
    @Option(name: .customLong("declaration"), parsing: .upToNextOption,
        help: "Declaration IDs to preview undo for") var declarations: [String] = []

    struct UndoPreview: Encodable {
        let component: String
        let generationID: String
        let declarations: [String]
        let restoredPayloadSHA256: String
        let touchedRecords: [PatchRecord]
    }
    struct Report: Encodable {
        let schemaVersion = 1
        let state: String
        let receipts: [FirmwareComponentReceipt.Record]?
        let undoPreview: UndoPreview?
    }

    func validate() throws {
        if undoComponent != nil {
            guard let generation, generation.utf8.count == 64,
                  generation.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !declarations.isEmpty, Set(declarations).count == declarations.count else {
                throw ValidationError("Undo preview requires --generation (64 lowercase hex characters) and unique --declaration IDs")
            }
        } else if generation != nil || !declarations.isEmpty {
            throw ValidationError("--generation and --declaration require --undo-component")
        }
    }

    static func report(in directory: URL, component: String? = nil, generation: String? = nil,
                       declarations: Set<String> = []) throws -> Report {
        let records = try FirmwareComponentReceipt.readCommitted(in: directory)
        var preview: UndoPreview?
        if let component {
            guard let generation else { throw ValidationError("Missing expected generation") }
            let source = try FirmwareComponentUndo.load(in: directory, component: component, generationID: generation)
            let restored = try source.restoring(declarations: declarations)
            preview = UndoPreview(component: component, generationID: generation, declarations: declarations.sorted(),
                restoredPayloadSHA256: VPhoneCreateDigest.sha256(restored.data), touchedRecords: restored.records)
        }
        return Report(state: records == nil ? "unknown" : "committed", receipts: records, undoPreview: preview)
    }

    func run() throws {
        let selected = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: selected)
        let report = try VPhoneBundleGuard.withBundleLock(directory: bundle.url, operation: VPhoneVMOperation.fwReceipts) { _ in
            try Self.report(in: bundle.url, component: undoComponent, generation: generation, declarations: Set(declarations))
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print("component evidence: \(report.state)")
            for receipt in report.receipts ?? [] {
                print("  \(receipt.component): \(receipt.scope.rawValue) \(receipt.state.rawValue), generation \(receipt.generationID), \(receipt.effects.count) records")
            }
            if let preview = report.undoPreview {
                print("undo preview: \(preview.component), \(preview.touchedRecords.count) records, restored payload SHA-256 \(preview.restoredPayloadSHA256)")
                print("Publication, code-page attestation and runtime acceptance are not performed by this preview.")
            }
        }
    }
}

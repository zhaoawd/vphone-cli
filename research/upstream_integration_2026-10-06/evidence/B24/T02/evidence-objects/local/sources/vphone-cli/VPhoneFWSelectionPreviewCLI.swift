import ArgumentParser
import Foundation
import FirmwarePatcher

/// T09 migration preview. No VM, firmware, selection file or receipt is written.
struct VPhoneFWSelectionPreviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selection-preview",
        abstract: "Preview legacy patch ID and bundled preset migration (read-only JSON)",
        discussion: """
        Preserves explicit enable/disable overrides and the local variant. Recognizing
        a target ID does not establish implementation, applicability or boot support.
        Use fw plan for current local execution gates. This command does not migrate a file.
        """)

    @Option(name: [.customShort("V"), .long], help: "Local variant: regular | dev | jb | exp | less")
    var variant: PatchFirmwareCLI.VariantOption = .regular
    @Option(help: "Optional shipped preset: standard | experimental | extended (legacy)")
    var bundledPreset: String?
    @Option(name: .customLong("select"), parsing: .upToNextOption, help: "Explicitly enabled IDs; legacy dotted IDs accepted")
    var select: [String] = []
    @Option(name: .customLong("block"), parsing: .upToNextOption, help: "Explicitly disabled IDs; duplicate/contradictory IDs rejected")
    var block: [String] = []

    struct Report: Encodable {
        let variant: String
        let bundledPreset: String?
        let selection: PatchSelectionMigration.Preview
    }

    func run() throws {
        let preset = try bundledPreset.map { try PatchSelectionMigration.migrateBundledPreset($0) }
        let selection = try PatchSelectionMigration.preview(select: select, block: block)
        let report = Report(variant: variant.rawValue, bundledPreset: preset, selection: selection)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}

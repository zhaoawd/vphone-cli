import ArgumentParser
import Foundation
import FirmwarePatcher

struct VPhoneFWSelectionMigrateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selection-migrate",
        abstract: "Preview or atomically migrate an explicit upstream PatchSelection.plist",
        discussion: """
        Default: read-only JSON preview. --apply requires --expected-source-sha256 from
        that preview. The directory must be idle. Original bytes are backed up before
        replacement. This migrates desired overrides only; it does not resolve a plan,
        change a local variant, patch firmware, or install guest components.
        """)

    @Argument(help: "Explicit path to the legacy XML PatchSelection.plist")
    var file: String
    @Flag(help: "Apply the previewed migration after preserving the original")
    var apply = false
    @Option(help: "Source SHA-256 from the preview; required with --apply")
    var expectedSourceSha256: String?

    mutating func validate() throws {
        if apply, expectedSourceSha256 == nil {
            throw ValidationError("--apply requires --expected-source-sha256 from the preview")
        }
        if !apply, expectedSourceSha256 != nil {
            throw ValidationError("--expected-source-sha256 is only used with --apply")
        }
    }

    func run() throws {
        let prepared = try PatchSelectionFileMigration.prepare(file: URL(fileURLWithPath: file))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if apply {
            guard let expectedSourceSha256 else {
                throw ValidationError("--apply requires --expected-source-sha256 from the preview")
            }
            let result = try PatchSelectionFileMigration.apply(prepared, expectedSourceSHA256: expectedSourceSha256)
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } else {
            print(String(decoding: try encoder.encode(prepared.preview), as: UTF8.self))
        }
    }
}

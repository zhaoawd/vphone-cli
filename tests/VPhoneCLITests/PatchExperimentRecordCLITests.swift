import ArgumentParser
import FirmwarePatcher
import Foundation
import Testing
@testable import vphone_cli

/// C5 CLI wiring: `patch-firmware --record-out`, `fw record show` and `fw record compare`.
struct PatchExperimentRecordCLITests {
    private func workspace(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c5-cli-" + UUID().uuidString)
        let restore = dir.appendingPathComponent("vm/iPhone17,3_26.1_23B85_Restore")
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0, count: 64).write(to: dir.appendingPathComponent("vm/AVPBooter.vresearch1.bin"))
        for (name, build) in [("iPhone-BuildManifest.plist", "23B85"), ("BuildManifest.plist", "23B85")] {
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["ProductVersion": "26.1", "ProductBuildVersion": build], format: .xml, options: 0)
            try plist.write(to: restore.appendingPathComponent(name))
        }
        try body(dir)
    }

    private func exitCode(_ body: () throws -> Void) -> Int32 {
        do { try body(); return 0 } catch let code as ExitCode { return code.rawValue } catch { return -1 }
    }

    @Test func failedPatchRunWritesARecordThatShowAndCompareAccept() throws {
        try workspace { dir in
            let record = dir.appendingPathComponent("records/run.json")
            try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Synthetic AVPBooter bytes: the required patch fails after the record was started.
            var patch = try PatchFirmwareCLI.parse(["--vm-directory", dir.appendingPathComponent("vm").path,
                                                    "--record-out", record.path, "--quiet"])
            #expect(throws: (any Error).self) { try patch.run() }

            let loaded = try PatchExperimentRecord.load(from: record)
            #expect(loaded.status == .failed)
            let summary = try String(contentsOf: PatchExperimentRecord.summaryURL(for: record), encoding: .utf8)
            #expect(summary == loaded.summary())
            #expect(summary.contains("23B85"))

            let show = try VPhoneFWRecordShowCommand.parse([record.path])
            #expect(exitCode { try show.run() } == 0)
            // Same record: conditions and patch results match, but a failed run has no
            // committed outputs, so the artifact result is undetermined (exit 1).
            let same = try VPhoneFWRecordCompareCommand.parse([record.path, record.path])
            #expect(exitCode { try same.run() } == 1)
            let comparison = try PatchExperimentRecord.compare(loaded, loaded)
            #expect(comparison.conditions.result == .same)
            #expect(comparison.patchResults.result == .same)
            #expect(comparison.artifacts.result == .undetermined)

            let corrupt = dir.appendingPathComponent("records/corrupt.json")
            try Data(try Data(contentsOf: record).prefix(40)).write(to: corrupt)
            let invalid = try VPhoneFWRecordCompareCommand.parse([record.path, corrupt.path])
            #expect(exitCode { try invalid.run() } == 2)
        }
    }
}

import Foundation
import CryptoKit
import Testing
@testable import FirmwarePatcher

/// Read-only verification of completed less outputs; never invokes filesystem patching.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_LESS_OUTPUT_PARITY_ROOT"] != nil))
struct LessOutputParityTests {
    @Test func actualManifestAndBootOutputsMatchLegacy() throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["VPHONE_LESS_OUTPUT_PARITY_ROOT"])).standardizedFileURL
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let expected = repository.appendingPathComponent("research/artifacts/c3-less-pipeline-2026-09-10")
        try #require(root == expected && root.resolvingSymlinksInPath() == root)
        let restore = root.appendingPathComponent("vm/iPhone17,3_26.1_23B85_Restore")
        let report = try JSONDecoder().decode(PatchRunReport.self,
            from: Data(contentsOf: root.appendingPathComponent("pipeline.report.json")))
        try #require(report.variant == "less" && report.failedRequired.isEmpty && !report.isAblationRun)
        let hashes = try #require(report.components.first { $0.component.lowercased() == "manifest" })
        try #require(hashes.records.count == 1)
        let input = hashes.records[0].originalBytes
        let legacy = ManifestHashPatcher(data: input, restoreDir: restore, verbose: false)
        let legacyRecords = try legacy.findAll()
        _ = try legacy.apply()
        let structured = StructuredExecution.run(
            patcher: ManifestHashPatcher(data: input, restoreDir: restore, verbose: false),
            componentName: hashes.component, gates: report.gates, ablate: [], fallback: input)
        #expect(!structured.report.hasRequiredFailure)
        #expect(structured.report.records == legacyRecords)
        #expect(structured.data == legacy.patchedData)
        #expect(hashes.records == legacyRecords)
        #expect(try Data(contentsOf: restore.appendingPathComponent("BuildManifest.plist")) == legacy.patchedData)
        print("C3 less actual Manifest: legacy/structured records and saved payload compared")

        // Prove that the pristine files used for the legacy comparison are the
        // inputs staged for this actual less run, using its saved input hashes.
        let staging = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("staging.json"))) as? [String: Any])
        let files = try #require(staging["files"] as? [[String: Any]])
        let stock = repository.appendingPathComponent("research/artifacts/c3-full-pipeline-2026-09-10/stock/cloudos")
        let paths = ["iBEC": "Firmware/dfu/iBEC.vresearch101.RELEASE.im4p",
                     "LLB": "Firmware/all_flash/LLB.vresearch101.RELEASE.im4p",
                     "DeviceTree": "Firmware/all_flash/DeviceTree.vphone600ap.im4p"]
        for (name, path) in paths {
            let raw = try Data(contentsOf: stock.appendingPathComponent(path))
            let staged = try #require(files.first { ($0["member"] as? String) == path })
            #expect(staged["source"] as? String == "cloudos")
            let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
            try #require(staged["local_sha256"] as? String == digest)
            let payload = try IM4PHandler.load(contentsOf: stock.appendingPathComponent(path)).payload
            let records: [PatchRecord]
            let data: Data
            if name == "DeviceTree" {
                let patcher = DeviceTreePatcher(data: payload, verbose: false, includeIdentityPatches: false)
                records = try patcher.findAll()
                _ = try patcher.apply()
                data = patcher.patchedData
            } else {
                let patcher = IBootPatcher(data: payload, mode: name == "iBEC" ? .ibec : .llb, verbose: false)
                patcher.extraBootArgs = ""
                records = try patcher.findAll()
                _ = try patcher.apply()
                data = patcher.patchedData
            }
            let actual = report.components.filter { $0.component == name }.flatMap(\.records)
            #expect(!records.isEmpty)
            #expect(actual == records)
            #expect(try IM4PHandler.load(contentsOf: restore.appendingPathComponent(path)).payload == data)
            print("C3 less actual \(name): original input hash, legacy records and saved payload compared")
        }
    }
}

import Foundation
import Testing
@testable import FirmwarePatcher

// Destructive only inside an explicitly supplied, separately cloned restore tree.
// Run manually with the version-matched seal tool and privileges for image mounts.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_LESS_ACCEPTANCE_RESTORE"] != nil))
struct LessFilesystemAcceptanceTests {
    @Test func completeFilesystemAndManifest() throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["VPHONE_LESS_ACCEPTANCE_RESTORE"]))
        #expect(root.path.contains("research/artifacts/c3-less-"))
        guard root.path.contains("research/artifacts/c3-less-") else { return }
        let manifest = root.appendingPathComponent("BuildManifest.plist")
        let input = try Data(contentsOf: manifest)
        let p = CryptexFilesystemPatcher(buildManiest: input, restoreDir: root, verbose: true)
        let gates = PatchGateSnapshot(variant: "less", iosBaseIs18: false, iosBaseIs27: false,
            cloudOSIsFridaCapable: false, forceExcGuard: false, enableFrida: false,
            excGuardActive: false, applyIOS27: false, applyFrida: false)
        let result = StructuredExecution.run(patcher: p, componentName: "filesystem", gates: gates, ablate: [], fallback: input)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.report).write(to: root.appendingPathComponent("filesystem.report.json"))
        #expect(!result.report.hasRequiredFailure)
        guard !result.report.hasRequiredFailure else { return }
        try result.data.write(to: manifest)
        let hashes = ManifestHashPatcher(data: result.data, restoreDir: root, verbose: true)
        let final = StructuredExecution.run(patcher: hashes, componentName: "manifest", gates: gates, ablate: [], fallback: result.data)
        try encoder.encode(final.report).write(to: root.appendingPathComponent("manifest.report.json"))
        #expect(!final.report.hasRequiredFailure)
        guard !final.report.hasRequiredFailure else { return }
        try final.data.write(to: manifest)
        let plist = try #require(try PropertyListSerialization.propertyList(from: final.data, format: nil) as? [String: Any])
        let identities = try #require(plist["BuildIdentities"] as? [[String: Any]])
        let components = try #require(identities.first?["Manifest"] as? [String: [String: Any]])
        for name in ["OS", "StaticTrustCache", "Ap,SystemVolumeCanonicalMetadata", "SystemVolume"] {
            let info = try #require(components[name]?["Info"] as? [String: Any])
            let path = try #require(info["Path"] as? String)
            let url = root.appendingPathComponent(path).standardizedFileURL
            #expect(url.path.hasPrefix(root.standardizedFileURL.path + "/"))
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            #expect((size ?? 0) > 0)
        }
    }
}

// Runs only against the newly staged, isolated complete restore tree.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_LESS_PIPELINE_VM"] != nil))
struct LessPipelineAcceptanceTests {
    @Test func completeProductionPipeline() throws {
        let env = ProcessInfo.processInfo.environment
        let vm = URL(fileURLWithPath: try #require(env["VPHONE_LESS_PIPELINE_VM"])).standardizedFileURL
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("research/artifacts/c3-less-pipeline-2026-09-10/vm").standardizedFileURL
        try #require(vm == expected && vm.resolvingSymlinksInPath() == expected)
        let root = vm.appendingPathComponent("iPhone17,3_26.1_23B85_Restore")
        try #require(root.resolvingSymlinksInPath() == root)
        let manifest = root.appendingPathComponent("BuildManifest.plist")
        let input = try Data(contentsOf: manifest)
        let report = try FirmwarePipeline(vmDirectory: vm, variant: .less, verbose: true)
            .patchAllStructured(ablate: [], allowOutput: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: vm.deletingLastPathComponent().appendingPathComponent("pipeline.report.json"))
        try #require(report.failedRequired.isEmpty)
        #expect(!report.isAblationRun)
        #expect(report.components.allSatisfy { $0.coverage == .structured })
        let filesystem = try #require(report.components.first { $0.component.lowercased() == "filesystem" })
        let hashes = try #require(report.components.first { $0.component.lowercased() == "manifest" })
        try #require(filesystem.records.count == 1 && hashes.records.count == 1)
        #expect(filesystem.records[0].originalBytes == input)
        #expect(filesystem.records[0].patchedBytes == hashes.records[0].originalBytes)
        let final = try Data(contentsOf: manifest)
        #expect(final == hashes.records[0].patchedBytes)
        let plist = try #require(try PropertyListSerialization.propertyList(from: final, format: nil) as? [String: Any])
        let identities = try #require(plist["BuildIdentities"] as? [[String: Any]])
        let components = try #require(identities.first?["Manifest"] as? [String: [String: Any]])
        for name in ["OS", "StaticTrustCache", "Ap,SystemVolumeCanonicalMetadata", "SystemVolume"] {
            let info = try #require(components[name]?["Info"] as? [String: Any])
            let path = try #require(info["Path"] as? String)
            let url = root.appendingPathComponent(path).standardizedFileURL
            try #require(url.path.hasPrefix(root.path + "/") && url.resolvingSymlinksInPath() == url)
            #expect((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
        }
    }
}

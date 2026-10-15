import CryptoKit
import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareKernelDSCAtlasTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_DSC_SYSTEM_ROOT"] != nil))
    func installedDSCWithAtlasValidatesThroughProductionPath() throws {
        let root = try #require(ProcessInfo.processInfo.environment["VPHONE_DSC_SYSTEM_ROOT"])
        try FirmwareKernelDSC.validate(system: URL(fileURLWithPath: root).standardizedFileURL,
            region: .init(base: 0x180000000, size: 7 << 30))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_DSC_EXP_PLAN"] != nil))
    func reproducedEXPKernelAcceptsInstalledDSC() throws {
        let env = ProcessInfo.processInfo.environment
        let system = URL(fileURLWithPath: try #require(env["VPHONE_DSC_SYSTEM_ROOT"])).standardizedFileURL
        let input = try Data(contentsOf: URL(fileURLWithPath: try #require(env["VPHONE_DSC_KERNEL_INPUT"])))
        let record = try JSONDecoder().decode(FirmwareDesiredPlanStore.Record.self,
            from: Data(contentsOf: URL(fileURLWithPath: try #require(env["VPHONE_DSC_EXP_PLAN"]))))
        let variant = try #require(FirmwarePipeline.Variant(rawValue: record.plan.variant))
        let pipeline = FirmwarePipeline(vmDirectory: system, variant: variant, verbose: false)
        let (payload, reports) = try pipeline.reproduceInstalledComponentReport("kernelcache", input: input, plan: record.plan)
        let report = PatchRunReport(variant: record.plan.variant, gates: record.plan.gates, components: reports, ablation: [])
        try PatchDeclarationGate.enforceKernel(report: report, plan: record.plan)
        let region = try FirmwareKernelRegion.inspect(payload)
        #expect(region.base == 0x180000000)
        #expect(region.size == 6 << 30)
        try FirmwareKernelDSC.validate(system: system, region: region)
        print("Verified EXP candidate payload SHA256:", SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        print("Verified EXP candidate report:", String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        print("Verified EXP candidate region: base=\(region.base), size=\(region.size); installed DSC accepted")
    }

    @Test(arguments: [".atlas", ".01.atlas", ".atlas.extra", "referenced-atlas"])
    func atlasSidecarDoesNotBecomeAnUnreferencedSubcache(_ suffix: String) throws {
        let system = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = system.appendingPathComponent("System/Cryptexes/OS/System/Library/Caches/com.apple.dyld")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: system) }
        var data = Data(repeating: 0, count: 0x1000)
        data.replaceSubrange(0..<7, with: Data("dyld_v1".utf8))
        func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
        }
        put(UInt32(0x200), 0x10); put(UInt32(1), 0x14)
        put(UInt64(0x180000000), 0xE0); put(UInt64(0x1000), 0xE8)
        put(UInt64(0x180000000), 0x200); put(UInt64(0x1000), 0x208)
        try data.write(to: directory.appendingPathComponent("dyld_shared_cache_arm64e"))
        let region = FirmwareKernelRegion.Region(base: 0x180000000, size: 7 << 30)
        try FirmwareKernelDSC.validate(system: system, region: region)
        if suffix == "referenced-atlas" {
            put(UInt32(0x280), 0x188); put(UInt32(1), 0x18C)
            data.replaceSubrange(0x298..<0x29E, with: Data(".atlas".utf8))
            try data.write(to: directory.appendingPathComponent("dyld_shared_cache_arm64e"))
        }
        let sidecar = suffix == "referenced-atlas" ? ".atlas" : suffix
        try Data("atlas sidecar".utf8).write(to: directory.appendingPathComponent("dyld_shared_cache_arm64e" + sidecar))
        if suffix == ".atlas" { try FirmwareKernelDSC.validate(system: system, region: region) }
        else { #expect(throws: (any Error).self) { try FirmwareKernelDSC.validate(system: system, region: region) } }
    }
}

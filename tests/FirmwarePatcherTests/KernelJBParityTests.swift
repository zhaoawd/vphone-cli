@testable import FirmwarePatcher
import Foundation
import Testing

struct KernelJBParityTests {
    /// Optional fixtures are explicitly disabled, rather than returning a false pass.
    /// A baseline prefix selects records/data captured before the migration; otherwise
    /// compare with the retained findAll path on a fresh instance of the current code.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_TEST_KERNELCACHE_IM4P"] != nil))
    func realKernelGateMatrix() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["VPHONE_TEST_KERNELCACHE_IM4P"])
        let input = try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path)).payload
        let base = KernelPatcher(data: input, verbose: false, isDev: false, applyExcGuard: false)
        _ = try base.findAll()
        let jbInput = base.buffer.data
        for ios27 in [false, true] {
            for frida in [false, true] {
                let expectedRecords: [PatchRecord]
                let expectedData: Data
                if let prefix = env["VPHONE_TEST_JB_BASELINE_PREFIX"] {
                    let stem = "\(prefix)-\(ios27)-\(frida)"
                    expectedRecords = try JSONDecoder().decode([PatchRecord].self,
                        from: Data(contentsOf: URL(fileURLWithPath: stem + ".json")))
                    expectedData = try Data(contentsOf: URL(fileURLWithPath: stem + ".bin"))
                } else {
                    let legacy = KernelJBPatcher(data: jbInput, verbose: false)
                    legacy.applyIOS27 = ios27
                    legacy.applyFrida = frida
                    expectedRecords = try legacy.findAll()
                    _ = try legacy.apply()
                    expectedData = legacy.buffer.data
                }
                let patcher = KernelJBPatcher(data: jbInput, verbose: false)
                patcher.applyIOS27 = ios27
                patcher.applyFrida = frida
                let (report, output) = StructuredExecution.run(
                    patcher: patcher, componentName: "kernelcache",
                    gates: KernelJBStructuredTests.gates(ios27: ios27, frida: frida),
                    ablate: [], fallback: jbInput)
                #expect(report.results.count == 33)
                #expect(report.records == expectedRecords, "ios27=\(ios27) frida=\(frida)")
                #expect(!report.records.isEmpty)
                #expect(output == expectedData, "ios27=\(ios27) frida=\(frida)")
                #expect(report.results.flatMap(\.recordIndices) == Array(report.records.indices))
                let failures = report.results.filter(\.isRequiredFailure).map { $0.id.method }
                print("JB parity ios27=\(ios27) frida=\(frida): \(report.records.count) records; required failures: \(failures)")
                for result in report.results where result.outcome == .alreadyApplied {
                    #expect(result.recordIndices.allSatisfy { index in
                        report.records[index].originalBytes == report.records[index].patchedBytes
                    })
                }
            }
        }
    }
}

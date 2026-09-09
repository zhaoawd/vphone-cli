import Foundation
import Testing
@testable import FirmwarePatcher

struct ExpStructuredTests {
    @Test func expRequiresBothOidAndCallersAndAcceptsVerifiedIdempotence() {
        let complete = Data("\0hv_vmm_present\0\0kern.hv_vmm_present\0".utf8)
        func run(_ input: Data, ablate: Set<String> = []) -> (ComponentReport, Data) {
            let result = StructuredExecution.run(patcher: KernelEXPPatcher(data: input, verbose: false),
                componentName: "kernelcache", gates: StructuredPatchResultTests.gates(),
                ablate: ablate, fallback: input)
            return (result.report, result.data)
        }
        let (first, patched) = run(complete)
        #expect(!first.hasRequiredFailure)
        #expect(first.records.count == 2)
        #expect(first.results.first?.outcome == .applied)
        let (second, twice) = run(patched)
        #expect(second.results.first?.outcome == .alreadyApplied)
        #expect(twice == patched)
        for partial in ["\0hv_vmm_present\0", "\0kern.hv_vmm_present\0",
                        "\0hv_vmm_present\0\0hv_vmm_present\0\0kern.hv_vmm_present\0"] {
            #expect(run(Data(partial.utf8)).0.hasRequiredFailure)
        }
        let (ablated, untouched) = run(complete, ablate: ["kernelcache.KernelEXPPatcher.patchHvVmmRename"])
        #expect(ablated.records.isEmpty)
        #expect(untouched == complete)
    }

}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_TEST_KERNEL_IM4P"] != nil))
struct ExpStructuredParityTests {
    @Test func expKernelRecordsAndPayloadMatch() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_TEST_KERNEL_IM4P"])
        let payload = try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path)).payload
        let old = KernelEXPPatcher(data: payload, verbose: false)
        let records = try old.findAll()
        _ = try old.apply()
        let result = StructuredExecution.run(patcher: KernelEXPPatcher(data: payload, verbose: false),
            componentName: "kernelcache", gates: StructuredPatchResultTests.gates(), ablate: [], fallback: payload)
        #expect(!records.isEmpty)
        #expect(records == result.report.records)
        #expect(old.patchedData == result.data)
        #expect(!result.report.hasRequiredFailure)
    }

}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_TEST_KERNEL_CHAIN"] == "1"))
struct KernelPipelineParityTests {
    @Test func baseJBAndEXPComposeWithoutChangingBytes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_TEST_KERNEL_IM4P"])
        let payload = try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path)).payload
        let ios27 = ProcessInfo.processInfo.environment["VPHONE_TEST_CHAIN_IOS27"] == "1"
        let frida = ProcessInfo.processInfo.environment["VPHONE_TEST_FRIDA"] == "1"
        let factories: [(Data, Bool) -> any Patcher] = [
            { KernelPatcher(data: $0, verbose: $1) },
            { data, verbose in
                let p = KernelJBPatcher(data: data, verbose: verbose)
                p.applyIOS27 = ios27
                p.applyFrida = frida
                return p
            },
            { KernelEXPPatcher(data: $0, verbose: $1) },
        ]
        let pipeline = FirmwarePipeline(vmDirectory: URL(fileURLWithPath: "/unused"), variant: .exp, verbose: false)
        let (oldData, oldRecords) = try pipeline.patchData(payload, componentName: "kernelcache", patcherFactories: factories)
        let (newData, reports) = try pipeline.patchDataStructured(payload, componentName: "kernelcache",
            patcherFactories: factories, gates: StructuredPatchResultTests.gates(iosBaseIs27: ios27, applyFrida: frida), ablate: [])
        #expect(oldData == newData)
        #expect(oldRecords == reports.flatMap(\.records))
        let failures = reports.flatMap(\.results).filter { $0.outcome == .failed }.map { $0.id.description }
        #expect(failures.isEmpty)
        #expect(reports.count == 3)
        print("C3 EXP composed pipeline: \(oldRecords.count) records; ios27=\(ios27) frida=\(frida)")
    }
}

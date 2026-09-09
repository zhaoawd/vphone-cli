import Foundation
import Testing
@testable import FirmwarePatcher

struct KernelStructuredTests {
    private let data = Data(repeating: 0, count: 0x400)

    @Test func baseKernelMissingMethodsFailIndividually() {
        let p = KernelPatcher(data: data, verbose: false)
        let result = StructuredExecution.run(patcher: p, componentName: "kernelcache",
            gates: StructuredPatchResultTests.gates(), ablate: [], fallback: data)
        #expect(result.report.coverage == .structured)
        #expect(result.report.results.count == 12)
        #expect(result.report.results.filter { $0.outcome == .failed }.count == 11)
        #expect(result.report.results.last?.outcome == .notApplicable)
        #expect(result.report.hasRequiredFailure)
        #expect(result.data == data)
    }

    @Test func disabledConditionalAndAblationNeverWriteDuringDiscovery() {
        for ablate: Set<String> in [[], ["kernelcache"]] {
            let p = WriteThroughKernel(data: data, verbose: false)
            let result = StructuredExecution.run(patcher: p, componentName: "kernelcache",
                gates: StructuredPatchResultTests.gates(), ablate: ablate, fallback: data)
            #expect(p.patches.isEmpty)
            #expect(p.buffer.data == data)
            #expect(result.report.results.first?.outcome == (ablate.isEmpty ? .notApplicable : .ablated))
        }
    }

    @Test func partialGroupFailsEvenWithAnExistingSuccessfulRecord() {
        let p = KernelPatcherBase(data: data, verbose: false)
        p.emit(0, Data([1]), patchID: "earlier", description: "earlier successful method")
        let before = p.patches.count
        p.emit(1, Data([2]), patchID: "partial", description: "first write of incomplete group")
        let raw = p.structuredMethodResult(completed: false, since: before)
        let outcome = PatchOutcomeMapping.outcome(for: raw, requirement: .required,
                                                 gates: StructuredPatchResultTests.gates())
        #expect(outcome.kind == .failed)
        #expect(outcome.reason?.contains("incomplete patch group") == true)
        #expect(p.structuredMethodResult(completed: true, since: p.patches.count) == .noMatch)
    }

    @Test func completedUnchangedRecordsAreIdempotent() {
        let p = KernelPatcherBase(data: data, verbose: false)
        p.emit(0, Data([0]), patchID: "same", description: "verified existing bytes")
        #expect(p.structuredMethodResult(completed: true, since: 0) == .idempotent)
        if case .failed = p.structuredMethodResult(completed: false, since: 0) {} else {
            Issue.record("An incomplete group must not become idempotent")
        }
    }

    @Test func baseMethodsMatchCompatibilityManifest() throws {
        let p = KernelPatcher(data: data, verbose: false)
        let steps = p.buildSteps()
        for variant in ["regular", "dev"] {
            let components = try C1AlignmentTests.components(variant: variant)
            let methods = try #require(components["kernelcache"]?.methods)
            #expect(Set(steps.map { $0.id.method }) == Set(methods.map(\.name)))
        }
        #expect(p.codeRanges.isEmpty)
        #expect(p.patches.isEmpty)
        #expect(steps.last?.requirement == .conditional(.excGuardActive))
    }
}

private final class WriteThroughKernel: KernelPatcherBase, StructuredPatcher {
    let component = "kernelcache"
    func findAll() throws -> [PatchRecord] { patches }
    func apply() throws -> Int { applyPatches() }
    func buildSteps() -> [PatchStep] {
        [PatchStep(id: PatchID(component: component, patcher: "WriteThroughKernel", method: "write"),
                   requirement: .conditional(.iosBaseIs27)) { [self] in
            emit(0, Data([1]), patchID: "write", description: "writes during discovery")
            return .matched
        }]
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VPHONE_TEST_KERNEL_IM4P"] != nil))
struct KernelStructuredParityTests {
    @Test(arguments: [false, true])
    func baseKernelRecordsAndPayloadMatch(isDev: Bool) throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_TEST_KERNEL_IM4P"])
        let payload = try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path)).payload
        let old = KernelPatcher(data: payload, verbose: false, isDev: isDev)
        let records = try old.findAll()
        _ = try old.apply()
        let new = KernelPatcher(data: payload, verbose: false, isDev: isDev)
        let gates = PatchGateSnapshot(variant: isDev ? "dev" : "regular",
            iosBaseIs18: false, iosBaseIs27: false, cloudOSIsFridaCapable: false,
            forceExcGuard: false, enableFrida: false, excGuardActive: isDev,
            applyIOS27: false, applyFrida: false)
        let result = StructuredExecution.run(patcher: new, componentName: "kernelcache",
            gates: gates, ablate: [], fallback: payload)
        #expect(!records.isEmpty)
        #expect(records == result.report.records)
        #expect(old.patchedData == result.data)
        print("C3 base parity dev=\(isDev): \(records.count) records; failures=\(result.report.results.filter { $0.outcome == .failed }.map { $0.id.method })")
    }
}

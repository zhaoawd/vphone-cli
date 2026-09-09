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
    @Test func jbMethodsMatchManifestAndMissingActiveMethodsFail() throws {
        let p = KernelJBPatcher(data: data, verbose: false)
        let steps = p.buildSteps()
        let base = KernelPatcher(data: data, verbose: false).buildSteps()
        let methods = try #require(C1AlignmentTests.components(variant: "jb")["kernelcache"]?.methods)
        #expect(Set((steps + base).map { $0.id.method }) == Set(methods.map(\.name)))
        #expect(steps.count == 33)
        let result = StructuredExecution.run(patcher: p, componentName: "kernelcache",
            gates: StructuredPatchResultTests.gates(), ablate: [], fallback: data)
        #expect(result.report.results.filter { $0.outcome == .notApplicable }.count == 9)
        #expect(result.report.results.filter { $0.outcome == .failed }.count == 24)
        #expect(result.report.hasRequiredFailure)
        #expect(result.data == data)
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
        if ProcessInfo.processInfo.environment["VPHONE_REQUIRE_COMPLETE"] == "1" {
            let failedMethods = result.report.results.filter { $0.outcome == .failed }.map { $0.id.method }
            #expect(failedMethods.isEmpty)
        }
        print("C3 base parity dev=\(isDev): \(records.count) records; failures=\(result.report.results.filter { $0.outcome == .failed }.map { $0.id.method })")
    }
    @Test(arguments: [false, true])
    func jbKernelRecordsAndPayloadMatch(ios27: Bool) throws {
        try assertJBParity(ios27: ios27, frida: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_TEST_FRIDA"] == "1"))
    func fridaKernelRecordsAndPayloadMatch() throws {
        try assertJBParity(ios27: true, frida: true)
    }

    private func assertJBParity(ios27: Bool, frida: Bool) throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_TEST_KERNEL_IM4P"])
        let payload = try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path)).payload
        let old = KernelJBPatcher(data: payload, verbose: false)
        old.applyIOS27 = ios27
        old.applyFrida = frida
        let records = try old.findAll()
        _ = try old.apply()
        let new = KernelJBPatcher(data: payload, verbose: false)
        new.applyIOS27 = ios27
        new.applyFrida = frida
        let result = StructuredExecution.run(patcher: new, componentName: "kernelcache",
            gates: StructuredPatchResultTests.gates(iosBaseIs27: ios27, applyFrida: frida), ablate: [], fallback: payload)
        #expect(!records.isEmpty)
        #expect(records == result.report.records)
        #expect(old.patchedData == result.data)
        if ProcessInfo.processInfo.environment["VPHONE_REQUIRE_COMPLETE"] == "1" {
            let failedMethods = Set(result.report.results.filter { $0.outcome == .failed }.map { $0.id.method })
            let expectedFailures = ios27 ? Set((ProcessInfo.processInfo.environment["VPHONE_EXPECT_IOS27_FAILURES"] ?? "")
                .split(separator: ",").map(String.init)) : []
            #expect(failedMethods == expectedFailures)
        }
        print("C3 JB parity ios27=\(ios27) frida=\(frida): \(records.count) records; failures=\(result.report.results.filter { $0.outcome == .failed }.map { $0.id.method })")
    }


}

import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FrozenStepExecutionTests {
    private final class Emitter: StructuredPatcher {
        let component = "ibss"
        let verbose = false
        let id = PatchID(component: "ibss", patcher: "IBootPatcher", method: "patchSerialLabels")
        var runs = 0
        var emittedRecords: [PatchRecord] = []
        var patchedData = Data([0])
        func buildSteps() -> [PatchStep] {
            [PatchStep(id: id, requirement: .optional) {
                self.runs += 1
                self.emittedRecords.append(PatchRecord(patchID: "serial.fixture", component: self.component,
                    fileOffset: 0, originalBytes: Data([0]), patchedBytes: Data([1]), description: "fixture"))
                return .matched
            }]
        }
        func commit(_ records: [PatchRecord]) {
            for record in records { patchedData.replaceSubrange(0..<1, with: record.patchedBytes) }
        }
        func findAll() throws -> [PatchRecord] { emittedRecords }
        func apply() throws -> Int { commit(emittedRecords); return emittedRecords.count }
    }

    @Test func excludedStepDoesNotRunOrModifyBytes() throws {
        let patcher = Emitter()
        let gates = DeclarationGateTests.gates()
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: gates, block: ["ibss-cfw-serial_label"])
        let output = StructuredExecution.run(patcher: patcher, componentName: "ibss", gates: gates,
            ablate: [], fallback: Data([0]), enabledSteps: plan.enabledSteps)
        #expect(patcher.runs == 0)
        #expect(output.data == Data([0]))
        #expect(output.report.records.isEmpty)
        #expect(output.report.results.first?.outcome == .notApplicable)
        let report = PatchRunReport(variant: "regular", gates: gates, components: [output.report], ablation: [])
        try PatchDeclarationGate.enforce(report: report, plan: plan)
    }

    @Test func selectedStepStillRunsAndWrites() throws {
        let patcher = Emitter()
        let gates = DeclarationGateTests.gates()
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: gates)
        let output = StructuredExecution.run(patcher: patcher, componentName: "ibss", gates: gates,
            ablate: [], fallback: Data([0]), enabledSteps: plan.enabledSteps)
        #expect(patcher.runs == 1)
        #expect(output.data == Data([1]))
        #expect(output.report.records.count == 1)
        let report = PatchRunReport(variant: "regular", gates: gates, components: [output.report], ablation: [])
        try PatchDeclarationGate.enforce(report: report, plan: plan)
    }
}

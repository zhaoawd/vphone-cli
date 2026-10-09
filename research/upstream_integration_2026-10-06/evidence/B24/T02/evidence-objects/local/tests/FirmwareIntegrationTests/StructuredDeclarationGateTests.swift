import Foundation
import Testing
@testable import FirmwarePatcher

struct StructuredDeclarationGateTests {
    enum Component: String, CaseIterable, Sendable {
        case avpbooter, ibss, ibec, llb, txm, txmDev, kernelcache, kernelcacheJB

        var payload: String {
            switch self {
            case .txmDev: "txm"
            case .kernelcacheJB: "kernelcache"
            default: rawValue
            }
        }
        var variant: String {
            switch self {
            case .txmDev: "dev"
            case .kernelcacheJB: "jb"
            default: "regular"
            }
        }

        func patcher(_ data: Data) -> any StructuredPatcher {
            switch self {
            case .avpbooter: AVPBooterPatcher(data: data, verbose: false)
            case .ibss: IBootPatcher(data: data, mode: .ibss, verbose: false)
            case .ibec: IBootPatcher(data: data, mode: .ibec, verbose: false)
            case .llb: IBootPatcher(data: data, mode: .llb, verbose: false)
            case .txm: TXMPatcher(data: data, verbose: false)
            case .txmDev: TXMDevPatcher(data: data, verbose: false)
            case .kernelcache: KernelPatcher(data: data, verbose: false)
            case .kernelcacheJB: KernelJBPatcher(data: data, verbose: false)
            }
        }
    }

    @Test(arguments: Component.allCases)
    func realBootChainRecordsPassTheDeclarationGate(component: Component) throws {
        let data = try Data(contentsOf: firmwareFixtureDirectory
            .appendingPathComponent("raw_payloads/\(component.payload).bin"))
        let gates = PatchGateSnapshot(variant: component.variant,
            iosBaseIs18: false, iosBaseIs27: false, cloudOSIsFridaCapable: false,
            forceExcGuard: false, enableFrida: false, excGuardActive: component == .txmDev,
            applyIOS27: false, applyFrida: false)
        let plan = try VariantPlanResolver.resolve(
            variant: #require(FirmwarePipeline.Variant(rawValue: component.variant)), gates: gates)
        let execution = StructuredExecution.run(patcher: component.patcher(data),
            componentName: component.payload, gates: gates, ablate: [], fallback: data,
            enabledSteps: plan.enabledSteps)
        let report = PatchRunReport(variant: component.variant, gates: gates,
            components: [execution.report], ablation: [])
        #expect(!execution.report.records.isEmpty)
        #expect(report.failedRequired.isEmpty)
        try PatchDeclarationGate.enforce(report: report, plan: plan)
        // Exercise refusal on actual emitted records, with their real patch IDs and
        // bytes: removing the ownership results must not allow publication.
        let orphan = ComponentReport(component: execution.report.component, coverage: .structured,
            results: [], records: execution.report.records)
        let broken = PatchRunReport(variant: component.variant, gates: gates,
            components: [orphan], ablation: [])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: broken, plan: plan)
        }
    }
    @Test func frozenBlockPreservesActualSerialLabelBytes() throws {
        let data = try Data(contentsOf: firmwareFixtureDirectory.appendingPathComponent("raw_payloads/ibss.bin"))
        let gates = PatchGateSnapshot(variant: "regular", iosBaseIs18: false, iosBaseIs27: false,
            cloudOSIsFridaCapable: false, forceExcGuard: false, enableFrida: false,
            excGuardActive: false, applyIOS27: false, applyFrida: false)
        let baselinePlan = try VariantPlanResolver.resolve(variant: .regular, gates: gates)
        let blockedPlan = try VariantPlanResolver.resolve(variant: .regular, gates: gates,
            block: ["ibss-cfw-serial_label"])
        func run(_ plan: VariantPlanResolver.VariantPlan) -> (report: ComponentReport, data: Data) {
            StructuredExecution.run(patcher: IBootPatcher(data: data, mode: .ibss, verbose: false),
                componentName: "ibss", gates: gates, ablate: [], fallback: data, enabledSteps: plan.enabledSteps)
        }
        let baseline = run(baselinePlan), blocked = run(blockedPlan)
        let serial = try #require(baseline.report.results.first { $0.id.method == "patchSerialLabels" })
        #expect(!serial.recordIndices.isEmpty)
        #expect(blocked.report.results.first { $0.id == serial.id }?.outcome == .notApplicable)
        for index in serial.recordIndices {
            let record = baseline.report.records[index]
            let range = record.fileOffset..<(record.fileOffset + record.originalBytes.count)
            #expect(blocked.data.subdata(in: range) == data.subdata(in: range))
        }
        let serialIndices = Set(serial.recordIndices)
        #expect(blocked.report.records == baseline.report.records.enumerated().filter {
            !serialIndices.contains($0.offset)
        }.map(\.element))
        let report = PatchRunReport(variant: "regular", gates: gates, components: [blocked.report], ablation: [])
        try PatchDeclarationGate.enforce(report: report, plan: blockedPlan)
    }

}

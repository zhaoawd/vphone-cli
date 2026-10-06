import Foundation
import Testing
@testable import FirmwarePatcher

struct StructuredDeclarationGateTests {
    enum Component: String, CaseIterable, Sendable {
        case avpbooter, ibss, ibec, llb, txm, txmDev

        var payload: String { self == .txmDev ? "txm" : rawValue }
        var variant: String { self == .txmDev ? "dev" : "regular" }

        func patcher(_ data: Data) -> any StructuredPatcher {
            switch self {
            case .avpbooter: AVPBooterPatcher(data: data, verbose: false)
            case .ibss: IBootPatcher(data: data, mode: .ibss, verbose: false)
            case .ibec: IBootPatcher(data: data, mode: .ibec, verbose: false)
            case .llb: IBootPatcher(data: data, mode: .llb, verbose: false)
            case .txm: TXMPatcher(data: data, verbose: false)
            case .txmDev: TXMDevPatcher(data: data, verbose: false)
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
        let execution = StructuredExecution.run(patcher: component.patcher(data),
            componentName: component.rawValue, gates: gates, ablate: [], fallback: data)
        let report = PatchRunReport(variant: component.variant, gates: gates,
            components: [execution.report], ablation: [])
        #expect(!execution.report.records.isEmpty)
        #expect(report.failedRequired.isEmpty)
        try PatchDeclarationGate.enforce(report: report, variant: component.variant, gates: gates)
        // Exercise refusal on actual emitted records, with their real patch IDs and
        // bytes: removing the ownership results must not allow publication.
        let orphan = ComponentReport(component: execution.report.component, coverage: .structured,
            results: [], records: execution.report.records)
        let broken = PatchRunReport(variant: component.variant, gates: gates,
            components: [orphan], ablation: [])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: broken, variant: component.variant, gates: gates)
        }
    }
}

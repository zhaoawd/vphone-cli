import Foundation
import Testing
@testable import FirmwarePatcher

struct KernelAlreadyAppliedEvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_KERNEL_REGION_FIXTURE"] != nil))
    func baseThenJBRetainsVerifiedOutputRecords() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_KERNEL_REGION_FIXTURE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let base = KernelPatcher(data: data, verbose: false, isDev: false)
        base.ensurePrepared()
        _ = base.patchPostValidationCMP()
        _ = base.patchBsdInitRootvp()
        #expect(base.emittedRecords.count == 2)
        #expect(base.emittedRecords.allSatisfy { $0.originalBytes != $0.patchedBytes })
        base.commit(base.emittedRecords)
        let input = base.patchedData
        let jb = KernelJBPatcher(data: input, verbose: false)
        jb.ensurePrepared()
        let gates = DeclarationGateTests.gates("exp")
        let enabled: Set<String> = ["kernelcache.KernelJBPatcher.patchPostValidationAdditional", "kernelcache.KernelJBPatcher.patchBsdInitAuth"]
        let execution = StructuredExecution.run(patcher: jb, componentName: "kernelcache", gates: gates,
            ablate: [], fallback: input, enabledSteps: enabled)
        let observed = execution.report.results.filter { enabled.contains($0.id.description) }
        #expect(observed.count == 2)
        #expect(observed.allSatisfy { $0.outcome == .alreadyApplied && $0.declarationEvidence?.isEmpty == false })
        for result in observed {
            let evidence = try #require(result.declarationEvidence)
            #expect(evidence.allSatisfy { $0.verifiedPayloadSHA256 == DeclarationExecutionEvidence.digest(input) && $0.verifiedOutputSHA256 != nil })
        }
        #expect(jb.buffer.data == input)
        #expect(jb.emittedRecords.filter { $0.originalBytes != $0.patchedBytes }.isEmpty)
        #expect(Set(jb.emittedRecords.map(\.patchID)) == ["jb.post_validation.cmp_w0_w0", "jb.bsd_init_auth.nop_cbnz"])
        for record in jb.emittedRecords {
            #expect(record.originalBytes == record.patchedBytes)
            #expect(input.subdata(in: record.fileOffset..<record.fileOffset + record.patchedBytes.count) == record.patchedBytes)
        }
    }
}

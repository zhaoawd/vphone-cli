import Foundation
import Testing
@testable import FirmwarePatcher

// Explicit original-kernel diagnostic loop; never part of the default fast run.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VPHONE_DIAG_KERNEL_IM4P"] != nil))
struct KernelGateDiagnosisTests {
    private func payload() throws -> Data {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_DIAG_KERNEL_IM4P"])
        return try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path)).payload
    }

    @Test func requiredDevExcGuardCompletes() throws {
        let p = KernelPatcher(data: try payload(), verbose: true, isDev: true)
        let step = try #require(p.buildSteps().first { $0.id.method == "patchExcGuardBehavior" })
        let raw = step.run()
        #expect(raw == .matched || raw == .idempotent)
    }

    @Test func requiredJBVmMapProtectCompletes() throws {
        let p = KernelJBPatcher(data: try payload(), verbose: true)
        let step = try #require(p.buildSteps().first { $0.id.method == "patchVmMapProtect" })
        let raw = step.run()
        #expect(raw == .matched || raw == .idempotent)
    }
}

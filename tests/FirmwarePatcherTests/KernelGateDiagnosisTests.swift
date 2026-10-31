import Foundation
import CryptoKit
import Capstone
import Testing
@testable import FirmwarePatcher

// Explicit original-kernel diagnostic loop; never part of the default fast run.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VPHONE_DIAG_KERNEL_IM4P"] != nil))
struct KernelGateDiagnosisTests {
    private func payload() throws -> Data {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_DIAG_KERNEL_IM4P"])
        return try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path)).payload
    }

    private func check(_ method: String, jb: Bool, expected261: UInt64, expected264: UInt64) throws {
        let data = try payload()
        func run(_ data: Data) throws -> (RawStepResult, KernelPatcherBase) {
            let p: KernelPatcherBase = jb ? KernelJBPatcher(data: data, verbose: true)
                : KernelPatcher(data: data, verbose: true, isDev: true)
            let structured = try #require(p as? any StructuredPatcher)
            let step = try #require(structured.buildSteps().first { $0.id.method == method })
            return (step.run(), p)
        }
        let (raw, p) = try run(data)
        #expect(raw == .matched)
        let record = try #require(p.patches.only)
        let inputPath = try #require(ProcessInfo.processInfo.environment["VPHONE_DIAG_KERNEL_IM4P"])
        let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: inputPath))).map { String(format: "%02x", $0) }.joined()
        let known: [String: UInt64] = [
            "b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac": expected261,
            "c853504319f27bfb3283253d8a5f36c3d0166ea7f4b178fca26fe6352b4de951": expected264,
        ]
        let expectedVA = try #require(known[hash])
        #expect(record.virtualAddress == expectedVA)
        #expect(record.originalBytes.count == 4 && record.patchedBytes.count == 4)
        var expected = data
        expected.replaceSubrange(record.fileOffset..<record.fileOffset + 4, with: record.patchedBytes)
        #expect(p.buffer.data == expected)
        let (again, repeated) = try run(expected)
        #expect(again == .idempotent)
        #expect(repeated.buffer.data == expected)

        // Mutate the semantic gate/AST anchor on this actual input: matching must fail,
        // even though the surrounding function and original string still exist.
        var damaged = data
        let scan = jb ? max(0, record.fileOffset - 24) : record.fileOffset
        let body = p.disasm.disassemble(in: data, at: scan, count: jb ? 6 : 64)
        let anchor = try #require(body.first {
            jb ? ($0.mnemonic == "mov" && p.disasm.immediate(at: 1, in: $0) == 6) : $0.mnemonic == "ldset"
        })
        damaged.replaceSubrange(Int(anchor.address)..<Int(anchor.address) + 4, with: ARM64.nop)
        let (failure, rejected) = try run(damaged)
        if case .failed = failure {} else { Issue.record("damaged semantic anchor must fail: \(failure)") }
        #expect(rejected.patches.isEmpty)
        #expect(rejected.buffer.data == damaged)
    }

    @Test func requiredDevExcGuardCompletes() throws {
        try check("patchExcGuardBehavior", jb: false,
                  expected261: 0xfffffe0007b53fcc, expected264: 0xfffffe0008d595c8)
    }

    @Test func requiredJBVmMapProtectCompletes() throws {
        try check("patchVmMapProtect", jb: true,
                  expected261: 0xfffffe0007bc424c, expected264: 0xfffffe0008dcaea0)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

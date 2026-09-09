// FirmwarePatcherTests.swift — Tests for ARM64 constants, encoders, and round-trip verification.

@testable import FirmwarePatcher
import Foundation
import Testing

struct ARM64ConstantTests {
    let disasm = ARM64Disassembler()

    func verifyConstant(_ data: Data, expectedMnemonic: String, file _: String = #file, line _: Int = #line) {
        let insn = disasm.disassembleOne(data, at: 0)
        #expect(insn != nil, "Failed to disassemble constant")
        #expect(insn?.mnemonic == expectedMnemonic,
                "Expected \(expectedMnemonic), got \(insn?.mnemonic ?? "nil")")
    }

    @Test func nop() {
        verifyConstant(ARM64.nop, expectedMnemonic: "nop")
    }

    @Test func ret() {
        verifyConstant(ARM64.ret, expectedMnemonic: "ret")
    }

    @Test func retaa() {
        verifyConstant(ARM64.retaa, expectedMnemonic: "retaa")
    }

    @Test func retab() {
        verifyConstant(ARM64.retab, expectedMnemonic: "retab")
    }

    @Test func pacibsp() {
        // PACIBSP is encoded as HINT #27, capstone may show it as "pacibsp" or "hint"
        let insn = disasm.disassembleOne(ARM64.pacibsp, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "pacibsp" || insn?.mnemonic == "hint")
    }

    @Test func movX0_0() {
        let insn = disasm.disassembleOne(ARM64.movX0_0, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func movX0_1() {
        let insn = disasm.disassembleOne(ARM64.movX0_1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func movW0_0() {
        let insn = disasm.disassembleOne(ARM64.movW0_0, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func movW0_1() {
        let insn = disasm.disassembleOne(ARM64.movW0_1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }

    @Test func cmpW0W0() {
        verifyConstant(ARM64.cmpW0W0, expectedMnemonic: "cmp")
    }

    @Test func cmpX0X0() {
        verifyConstant(ARM64.cmpX0X0, expectedMnemonic: "cmp")
    }

    @Test func movX0X20() {
        let insn = disasm.disassembleOne(ARM64.movX0X20, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "orr")
    }

    @Test func strbW0X20_30() {
        verifyConstant(ARM64.strbW0X20_30, expectedMnemonic: "strb")
    }

    @Test func movW0_0xA1() {
        let insn = disasm.disassembleOne(ARM64.movW0_0xA1, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "movz")
    }
}

struct ARM64EncoderTests {
    let disasm = ARM64Disassembler()

    @Test func typedOperandHelpersExposeRegisterAndImmediate() throws {
        let data = try #require(ARM64Encoder.encodeAddImm12(rd: 0, rn: 1, imm12: 0x100))
        let insn = try #require(disasm.disassembleOne(data, at: 0x1000))

        #expect(disasm.registerName(at: 0, in: insn) == "x0")
        #expect(disasm.registerName(at: 1, in: insn) == "x1")
        #expect(disasm.immediate(at: 2, in: insn) == 0x100)
        #expect(disasm.registerName(at: 3, in: insn) == nil)
    }

    @Test func encodeBCondEqForward() throws {
        let data = try #require(ARM64Encoder.encodeBCond(.eq, from: 0x1000, to: 0x1080))
        let insn = try #require(disasm.disassembleOne(data, at: 0x1000))

        #expect(insn.mnemonic == "b.eq")
        #expect(disasm.immediate(at: 0, in: insn) == 0x1080)
    }

    @Test func encodeCmpImmediateW() throws {
        let data = try #require(ARM64Encoder.encodeCmpImmediateW(rn: 2, imm12: 0x6E0))
        let insn = try #require(disasm.disassembleOne(data, at: 0))

        #expect(insn.mnemonic == "cmp")
        #expect(disasm.registerName(at: 0, in: insn) == "w2")
        #expect(disasm.immediate(at: 1, in: insn) == 0x6E0)
    }

    @Test func encodeCmpRegisterX() throws {
        let data = ARM64Encoder.encodeCmpRegisterX(rn: 9, rm: 10)
        let insn = try #require(disasm.disassembleOne(data, at: 0))

        #expect(insn.mnemonic == "cmp")
        #expect(disasm.registerName(at: 0, in: insn) == "x9")
        #expect(disasm.registerName(at: 1, in: insn) == "x10")
    }

    @Test func encodeLdrImmediateX() throws {
        let data = try #require(ARM64Encoder.encodeLdrImmediateX(rt: 8, rn: 8, offset: 0x3F0))
        let insn = try #require(disasm.disassembleOne(data, at: 0))

        #expect(insn.mnemonic == "ldr")
        #expect(disasm.registerName(at: 0, in: insn) == "x8")
        #expect(disasm.memoryBaseRegisterName(at: 1, in: insn) == "x8")
        #expect(insn.aarch64?.operands[1].mem.disp == 0x3F0)
    }

    @Test func encodeMovkX() throws {
        let data = try #require(ARM64Encoder.encodeMovkX(rd: 10, imm16: 0x6F73, shift: 16))
        let insn = try #require(disasm.disassembleOne(data, at: 0))

        #expect(insn.mnemonic == "movk")
        #expect(disasm.registerName(at: 0, in: insn) == "x10")
        #expect(disasm.immediate(at: 1, in: insn) == 0x6F73)
    }

    @Test func encodeMrsTpidrEl1() throws {
        let data = ARM64Encoder.encodeMrsTpidrEl1(rd: 8)
        let insn = try #require(disasm.disassembleOne(data, at: 0))

        #expect(insn.mnemonic == "mrs")
        #expect(disasm.registerName(at: 0, in: insn) == "x8")
    }

    @Test func encodeBForward() throws {
        // B from 0x1000 to 0x2000 (forward 0x1000 bytes)
        let data = ARM64Encoder.encodeB(from: 0x1000, to: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "b")
    }

    @Test func encodeBBackward() throws {
        // B from 0x2000 to 0x1000 (backward 0x1000 bytes)
        let data = ARM64Encoder.encodeB(from: 0x2000, to: 0x1000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x2000)
        #expect(insn?.mnemonic == "b")
    }

    @Test func encodeBLForward() throws {
        let data = ARM64Encoder.encodeBL(from: 0x1000, to: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "bl")
    }

    @Test func decodeBranchTarget() throws {
        // Encode a B, then decode and verify the target matches
        let from: UInt64 = 0x10000
        let to: UInt64 = 0x20000
        let data = try #require(ARM64Encoder.encodeB(from: Int(from), to: Int(to)))
        let insn: UInt32 = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let decoded = ARM64Encoder.decodeBranchTarget(insn: insn, pc: from)
        #expect(decoded == to)
    }

    @Test func encodeBOutOfRange() {
        // Try to encode a branch that's too far (> 128MB)
        let data = ARM64Encoder.encodeB(from: 0, to: 0x1000_0000)
        #expect(data == nil)
    }

    @Test func encodeADRP() throws {
        let data = ARM64Encoder.encodeADRP(rd: 0, pc: 0x1000, target: 0x2000)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0x1000)
        #expect(insn?.mnemonic == "adrp")
    }

    @Test func encodeAddImm12() throws {
        let data = ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 0x100)
        #expect(data != nil)
        let insn = try disasm.disassembleOne(#require(data), at: 0)
        #expect(insn?.mnemonic == "add")
    }

    @Test func encodeMovXFromZR() {
        // `mov x8, xzr` — the mac_mount state-clear encoding (ORR X8, XZR, XZR).
        let bytes = ARM64Encoder.encodeMovX(rd: 8, rm: 31)
        let insn = disasm.disassembleOne(bytes, at: 0)
        #expect(insn != nil)
        #expect(insn?.mnemonic == "mov" || insn?.mnemonic == "orr")
        // Byte-for-byte equal to the legacy hand-encoded constant 0xAA1F03E8.
        #expect(bytes == withUnsafeBytes(of: UInt32(0xAA1F_03E8).littleEndian) { Data($0) })
    }

    @Test func encodeMovXIsRegisterMove() {
        // `mov x0, x20` matches the project's preverified ARM64.movX0X20 constant.
        #expect(ARM64Encoder.encodeMovX(rd: 0, rm: 20) == ARM64.movX0X20)
    }

    @Test func encodeTestBitBranchRoundTrips() throws {
        // The vm_map_delete --frida patch retargets `tbz/tbnz w8,#9` to bit 13
        // (current-protection.X → max_protection.X), preserving sense and target.
        let tbz = try #require(ARM64Encoder.encodeTestBitBranch(
            nonzero: false, register: 8, bit: 13, from: 0x1000, to: 0x1020))
        let tbzI = try #require(disasm.disassembleOne(tbz, at: 0x1000))
        #expect(tbzI.mnemonic == "tbz")
        #expect(disasm.registerName(at: 0, in: tbzI) == "w8")
        #expect(disasm.immediate(at: 1, in: tbzI) == 13)
        #expect(disasm.immediate(at: 2, in: tbzI) == 0x1020)

        let tbnz = try #require(ARM64Encoder.encodeTestBitBranch(
            nonzero: true, register: 8, bit: 13, from: 0x2000, to: 0x1f00))
        let tbnzI = try #require(disasm.disassembleOne(tbnz, at: 0x2000))
        #expect(tbnzI.mnemonic == "tbnz")
        #expect(disasm.registerName(at: 0, in: tbnzI) == "w8")
        #expect(disasm.immediate(at: 1, in: tbnzI) == 13)
        #expect(disasm.immediate(at: 2, in: tbnzI) == 0x1F00)

        // Rejects bad register / bit / out-of-range target.
        #expect(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 32, bit: 13, from: 0, to: 4) == nil)
        #expect(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 64, from: 0, to: 4) == nil)
        #expect(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: 13, from: 0, to: 0x8000) == nil)
    }

    @Test func encodeMovzWClearsTSSFCheckEntitlement() throws {
        // The thread_set_state --frida patch rewrites `mov w6, #0x201`
        // (TSSF_TRANSLATE_TO_USER | TSSF_CHECK_ENTITLEMENT) to `mov w6, #0x1`,
        // clearing only the entitlement bit while preserving user translation.
        let bytes = try #require(ARM64Encoder.encodeMovzW(rd: 6, imm16: 0x1))
        let insn = try #require(disasm.disassembleOne(bytes, at: 0))
        #expect(insn.mnemonic == "mov" || insn.mnemonic == "movz")
        #expect(disasm.registerName(at: 0, in: insn) == "w6")
        #expect(disasm.immediate(at: 1, in: insn) == 1)
    }
}

struct FpfsScopedOpenCaveTests {
    let disasm = ARM64Disassembler()

    @Test func caveRoutesFileProviderDaemonsToRealHookAndAllowsOthers() throws {
        let patcher = KernelJBPatcher(data: Data(repeating: 0, count: 0x4000), verbose: false)
        let cave = try #require(patcher.buildScopedOpenCave(caveOff: 0x1000, realHookOff: 0x3000))
        let instructions = disasm.disassemble(cave, at: 0x1000)

        #expect(cave.count == 80)
        #expect(instructions.count == 20)
        #expect(instructions[0].mnemonic == "mrs")
        #expect(instructions[9].mnemonic == "cmp")
        #expect(instructions[10].mnemonic == "b.eq")
        #expect(instructions[15].mnemonic == "cmp")
        #expect(instructions[16].mnemonic == "b.eq")
        #expect(instructions[18].mnemonic == "ret")
        #expect(instructions[19].mnemonic == "b")
        #expect(disasm.registerName(at: 0, in: instructions[9]) == "x9")
        #expect(disasm.registerName(at: 1, in: instructions[9]) == "x10")
        #expect(disasm.registerName(at: 0, in: instructions[15]) == "x9")
        #expect(disasm.registerName(at: 1, in: instructions[15]) == "x10")
        #expect(disasm.immediate(at: 0, in: instructions[10]) == Int64(instructions[19].address))
        #expect(disasm.immediate(at: 0, in: instructions[16]) == Int64(instructions[19].address))
        #expect(disasm.immediate(at: 0, in: instructions[19]) == 0x3000)
    }
}

/// Round-trip coverage for the shared raw-instruction predicates in `ARM64Inst`,
/// the single source of truth for the JB pattern scanners. Each predicate is
/// cross-checked against Capstone's decode of the same word so the masks cannot
/// silently drift from the ISA.
struct ARM64InstTests {
    let disasm = ARM64Disassembler()

    private func mnemonic(of word: UInt32) -> String? {
        let data = withUnsafeBytes(of: word.littleEndian) { Data($0) }
        return disasm.disassembleOne(data, at: 0)?.mnemonic
    }

    @Test func fieldAccessors() {
        // ldr x1, [x0, #0x3e0]  → Rt=1, Rn=0
        let ldr: UInt32 = 0xF941_F001
        #expect(ARM64Inst.rd(ldr) == 1)
        #expect(ARM64Inst.rn(ldr) == 0)
        // cmp x0, x1 (SUBS XZR, X0, X1) → Rn=0, Rm=1
        let cmp: UInt32 = 0xEB01_001F
        #expect(ARM64Inst.rn(cmp) == 0)
        #expect(ARM64Inst.rm(cmp) == 1)
        // movz w0, #0x16 → imm16=0x16
        let movz: UInt32 = 0x5280_02C0
        #expect(ARM64Inst.movImm16(movz) == 0x16)
        // sub w2, w3, #1 → imm12=1
        let sub: UInt32 = 0x5100_0462
        #expect(ARM64Inst.addSubImm12(sub) == 1)
    }

    @Test func adrp() {
        let w: UInt32 = 0x9000_0000 // adrp x0, ...
        #expect(mnemonic(of: w) == "adrp")
        #expect(ARM64Inst.isADRP(w))
        #expect(!ARM64Inst.isADRP(0xF941_F001)) // an ldr is not adrp
    }

    @Test func ldrImm64() {
        let w: UInt32 = 0xF941_F001 // ldr x1, [x0, #0x3e0]
        #expect(mnemonic(of: w) == "ldr")
        #expect(ARM64Inst.isLDRImm64(w))
        #expect(!ARM64Inst.isLDRImm64(0x9000_0000))
    }

    @Test func cmpReg64() {
        let w: UInt32 = 0xEB01_001F // cmp x0, x1
        #expect(mnemonic(of: w) == "cmp")
        #expect(ARM64Inst.isCMPReg64(w))
        // operand order is irrelevant: cmp x1, x0
        #expect(ARM64Inst.isCMPReg64(0xEB00_003F))
        #expect(!ARM64Inst.isCMPReg64(0x5100_0462)) // sub-imm is not cmp-reg
    }

    @Test func subImm32() {
        let w: UInt32 = 0x5100_0462 // sub w2, w3, #1
        #expect(mnemonic(of: w) == "sub")
        #expect(ARM64Inst.isSUBImm32(w))
        #expect(!ARM64Inst.isSUBImm32(0x5280_02C0)) // movz is not sub
    }

    @Test func movzW() {
        let w: UInt32 = 0x5280_02C0 // movz w0, #0x16
        let m = mnemonic(of: w)
        #expect(m == "mov" || m == "movz")
        #expect(ARM64Inst.isMOVZW(w))
        #expect(ARM64Inst.rd(w) == 0)
        #expect(!ARM64Inst.isMOVZW(0xF941_F001))
    }

    @Test func andRegW() {
        let w: UInt32 = 0x0A05_0083 // and w3, w4, w5
        #expect(mnemonic(of: w) == "and")
        #expect(ARM64Inst.isANDRegW(w))
        #expect(!ARM64Inst.isANDRegW(0x5280_02C0))
    }

    @Test func lsrImm7W() {
        let w: UInt32 = 0x5307_7C20 // lsr w0, w1, #7
        let m = mnemonic(of: w)
        #expect(m == "lsr" || m == "ubfm")
        #expect(ARM64Inst.isLSRImm7W(w))
        #expect(!ARM64Inst.isLSRImm7W(0x0A05_0083))
    }

    @Test func branchPredicates() {
        let bl = ARM64Encoder.encodeBL(from: 0x1000, to: 0x2000)!
            .withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(ARM64Inst.isBL(bl))
        // b.eq vs b.ne (cond field)
        #expect(ARM64Inst.isBEQ(0x5400_0020)) // b.eq #4
        #expect(!ARM64Inst.isBEQ(0x5400_0021)) // b.ne #4
    }

    @Test func compareAndBranch() {
        #expect(ARM64Inst.isCBZW(0x3400_0020)) // cbz w0, #4
        #expect(!ARM64Inst.isCBZW(0x3500_0020)) // that is cbnz
        #expect(ARM64Inst.isCBNZW(0x3500_0020))
        #expect(ARM64Inst.isCBZorCBNZW(0x3400_0020))
        #expect(ARM64Inst.isCBZorCBNZW(0x3500_0020))
        #expect(ARM64Inst.isCBZX(0xB400_0020)) // cbz x0, #4 (64-bit)
        #expect(!ARM64Inst.isCBZX(0x3400_0020)) // 32-bit cbz is not the X form
    }
}

struct BinaryBufferTests {
    @Test func readWriteU32() {
        let data = Data(repeating: 0, count: 16)
        let buf = BinaryBuffer(data)
        buf.writeU32(at: 4, value: 0xDEAD_BEEF)
        #expect(buf.readU32(at: 4) == 0xDEAD_BEEF)
    }

    @Test func findString() {
        let testStr = "Hello, World!\0Extra"
        let data = Data(testStr.utf8)
        let buf = BinaryBuffer(data)
        let offset = buf.findString("Hello, World!")
        #expect(offset == 0)
    }

    @Test func findAll() {
        var data = Data(repeating: 0, count: 32)
        // Write NOP at offset 8 and 20
        let nop = ARM64.nop
        data.replaceSubrange(8 ..< 12, with: nop)
        data.replaceSubrange(20 ..< 24, with: nop)
        let buf = BinaryBuffer(data)
        let offsets = buf.findAll(nop)
        #expect(offsets.count == 2)
        #expect(offsets.contains(8))
        #expect(offsets.contains(20))
    }

    @Test func readUnalignedValues() {
        let data = Data([0xFF, 0x78, 0x56, 0x34, 0x12, 0xF0, 0xDE, 0xBC, 0x9A])
        let buf = BinaryBuffer(data)
        #expect(buf.readU32(at: 1) == 0x1234_5678)
        #expect(buf.readU64(at: 1) == 0x9ABC_DEF0_1234_5678)
    }
}

final class BytePatchPatcher: Patcher {
    let component = "test"
    let verbose = false
    let data: Data
    let offset: Int
    let byte: UInt8
    let id: String

    init(data: Data, offset: Int, byte: UInt8, id: String) {
        self.data = data
        self.offset = offset
        self.byte = byte
        self.id = id
    }

    func findAll() throws -> [PatchRecord] {
        [
            PatchRecord(
                patchID: id,
                component: component,
                fileOffset: offset,
                originalBytes: Data([data[offset]]),
                patchedBytes: Data([byte]),
                description: id
            ),
        ]
    }

    func apply() throws -> Int { 1 }
}

struct FirmwarePipelineDataFlowTests {
    @Test func chainedPatchersReceivePreviousPatchedBytes() throws {
        let pipeline = FirmwarePipeline(
            vmDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            verbose: false
        )
        var secondInput = Data()

        let (patched, records) = try pipeline.patchData(
            Data([0x00, 0x00]),
            componentName: "test",
            patcherFactories: [
                { data, _ in
                    BytePatchPatcher(data: data, offset: 0, byte: 0xAA, id: "first")
                },
                { data, _ in
                    secondInput = data
                    return BytePatchPatcher(data: data, offset: 1, byte: 0xBB, id: "second")
                },
            ]
        )

        #expect(secondInput == Data([0xAA, 0x00]))
        #expect(patched == Data([0xAA, 0xBB]))
        #expect(records.map(\.patchID) == ["first", "second"])
    }
}

struct IBootPatcherIdempotencyTests {
    @Test func serialLabelsPatchTwoBannerRunsWhenLabelAbsent() {
        let banner = String(repeating: "=", count: 32)
        let payload = Data("prefix \(banner) middle \(banner) suffix".utf8)
        let patcher = IBootPatcher(data: payload, mode: .ibss, verbose: false)

        patcher.patchSerialLabels()

        #expect(patcher.patches.count == 2)
        #expect(patcher.patches.allSatisfy {
            String(data: $0.patchedBytes, encoding: .ascii) == "Loaded iBSS"
        })
    }

    @Test func serialLabelsSkipWhenLabelAlreadyPresent() {
        let payload = Data("Loaded iBSS\0 middle Loaded iBSS\0 suffix".utf8)
        let patcher = IBootPatcher(data: payload, mode: .ibss, verbose: false)

        patcher.patchSerialLabels()

        #expect(patcher.patches.isEmpty)
    }

    @Test func serialLabelsDoNotSkipForUnrelatedSingleLabel() {
        let banner = String(repeating: "=", count: 32)
        let payload = Data("Loaded iBSS\0 prefix \(banner) middle \(banner) suffix".utf8)
        let patcher = IBootPatcher(data: payload, mode: .ibss, verbose: false)

        patcher.patchSerialLabels()

        #expect(patcher.patches.count == 2)
    }
}

struct FirmwarePipelineTests {
    @Test func findFileSupportsGlobPatterns() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let target = tempDir.appendingPathComponent("AVPBooter.vresearch1.bin")
        try Data([0xAA]).write(to: target)

        let pipeline = FirmwarePipeline(vmDirectory: tempDir, variant: .regular, verbose: false)
        let found = try pipeline.findFile(in: tempDir, patterns: ["AVPBooter*.bin"], label: "AVPBooter")

        // Directory enumeration can canonicalize /var to /private/var on macOS.
        #expect(found.resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
    }
}

struct FridaGatingTests {
    @Test func cloudOSVersionGate() {
        // Frida kernel patches apply on cloudOS 26.4+ only.
        #expect(FirmwarePipeline.productVersionAtLeast("26.4", 26, 4))
        #expect(FirmwarePipeline.productVersionAtLeast("26.5", 26, 4))
        #expect(FirmwarePipeline.productVersionAtLeast("26.10", 26, 4))
        #expect(FirmwarePipeline.productVersionAtLeast("27.0", 26, 4))
        #expect(!FirmwarePipeline.productVersionAtLeast("26.3", 26, 4))
        #expect(!FirmwarePipeline.productVersionAtLeast("18.5", 26, 4))
        #expect(!FirmwarePipeline.productVersionAtLeast(nil, 26, 4))
    }
}

// MARK: - C2: Structured patch results, requirements, and ablation

/// A minimal `StructuredPatcher` for exercising the structured result model without
/// real firmware. Built from `(PatchID, PatchRequirement, RawStepResult)` triples;
/// `matched`/`idempotent` steps append one record (idempotent records have equal
/// original/patched bytes), others append none.
final class SyntheticStructuredPatcher: StructuredPatcher {
    let componentName: String
    let verbose = false
    let steps: [(id: PatchID, requirement: PatchRequirement, raw: RawStepResult)]
    var patches: [PatchRecord] = []

    var component: String { componentName }

    init(component: String, steps: [(id: PatchID, requirement: PatchRequirement, raw: RawStepResult)]) {
        componentName = component
        self.steps = steps
    }

    private func record(for id: PatchID, idempotent: Bool) -> PatchRecord {
        PatchRecord(
            patchID: id.description,
            component: componentName,
            fileOffset: 0,
            originalBytes: Data([0x00]),
            patchedBytes: Data([idempotent ? 0x00 : 0xAA]),
            description: id.method
        )
    }

    func findAll() throws -> [PatchRecord] { patches }
    func apply() throws -> Int { patches.count }

    func buildSteps() -> [PatchStep] {
        steps.map { entry in
            PatchStep(id: entry.id, requirement: entry.requirement, run: { [self] in
                switch entry.raw {
                case .matched: patches.append(record(for: entry.id, idempotent: false))
                case .idempotent: patches.append(record(for: entry.id, idempotent: true))
                case .noMatch, .ambiguous, .encodeFail: break
                }
                return entry.raw
            })
        }
    }

    var emittedRecords: [PatchRecord] { patches }
    func commit(_: [PatchRecord]) {}
    var patchedData: Data { Data() }
}

struct StructuredPatchResultTests {
    static func gates(iosBaseIs27: Bool = false, applyFrida: Bool = false) -> PatchGateSnapshot {
        PatchGateSnapshot(
            variant: "test", iosBaseIs18: false, iosBaseIs27: iosBaseIs27,
            cloudOSIsFridaCapable: applyFrida, forceExcGuard: false, enableFrida: applyFrida,
            excGuardActive: false, applyIOS27: iosBaseIs27, applyFrida: applyFrida
        )
    }

    static func id(_ method: String, patcher: String = "SyntheticStructuredPatcher", component: String = "synthetic") -> PatchID {
        PatchID(component: component, patcher: patcher, method: method)
    }

    private static func pipeline() -> FirmwarePipeline {
        FirmwarePipeline(vmDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), verbose: false)
    }

    /// Drive a single synthetic patcher through the structured pipeline path.
    private func runComponent(
        _ steps: [(id: PatchID, requirement: PatchRequirement, raw: RawStepResult)],
        gates: PatchGateSnapshot,
        ablate: Set<String> = []
    ) throws -> ComponentReport {
        let pipeline = Self.pipeline()
        let (_, reports) = try pipeline.patchDataStructured(
            Data([0x00, 0x00, 0x00, 0x00]),
            componentName: "synthetic",
            patcherFactories: [{ _, _ in SyntheticStructuredPatcher(component: "synthetic", steps: steps) }],
            gates: gates,
            ablate: ablate
        )
        #expect(reports.count == 1)
        return reports[0]
    }

    // 1. Required missing → failed; component fails.
    @Test func requiredMissingFailsComponent() throws {
        let report = try runComponent(
            [(Self.id("patchRequired"), .required, .noMatch)],
            gates: Self.gates()
        )
        #expect(report.results[0].outcome == .failed)
        #expect(report.results[0].reason == "anchor not found")
        #expect(report.hasRequiredFailure)
    }

    // 2. Rule-driven notApplicable vs failed on the same step under different gates.
    @Test func conditionalRuleControlsNotApplicableVsFailed() throws {
        let step: [(id: PatchID, requirement: PatchRequirement, raw: RawStepResult)] =
            [(Self.id("patchIOS27Only"), .conditional(.iosBaseIs27), .noMatch)]

        let ruleFalse = try runComponent(step, gates: Self.gates(iosBaseIs27: false))
        #expect(ruleFalse.results[0].outcome == .notApplicable)
        #expect(!ruleFalse.hasRequiredFailure)

        let ruleTrue = try runComponent(step, gates: Self.gates(iosBaseIs27: true))
        #expect(ruleTrue.results[0].outcome == .failed)
        #expect(ruleTrue.hasRequiredFailure)
    }

    // 3. Idempotent → alreadyApplied; no failure.
    @Test func idempotentBecomesAlreadyApplied() throws {
        let report = try runComponent(
            [(Self.id("patchNonce"), .required, .idempotent)],
            gates: Self.gates()
        )
        #expect(report.results[0].outcome == .alreadyApplied)
        #expect(report.records.count == 1)
        #expect(!report.hasRequiredFailure)
    }

    // 4. Ambiguous → failed even when optional.
    @Test func ambiguousFailsEvenWhenOptional() throws {
        let report = try runComponent(
            [(Self.id("patchAmbiguous"), .optional, .ambiguous(count: 2))],
            gates: Self.gates()
        )
        #expect(report.results[0].outcome == .failed)
        #expect(report.results[0].reason == "expected 1 match, found 2")
        #expect(!report.hasRequiredFailure) // optional does not fail the component
    }

    // 5. Partial success within a component.
    @Test func partialSuccessKeepsAppliedResults() throws {
        let failing = try runComponent(
            [
                (Self.id("a"), .required, .matched),
                (Self.id("b"), .required, .matched),
                (Self.id("c"), .required, .noMatch),
            ],
            gates: Self.gates()
        )
        #expect(failing.hasRequiredFailure)
        #expect(failing.results.filter { $0.outcome == .applied }.count == 2)
        #expect(failing.records.count == 2)

        let optionalFail = try runComponent(
            [
                (Self.id("a"), .required, .matched),
                (Self.id("b"), .optional, .noMatch),
            ],
            gates: Self.gates()
        )
        #expect(!optionalFail.hasRequiredFailure)
    }

    // 6. Patch group requiring multiple records, one missing → group/component fails.
    @Test func patchGroupMissingOneRecordFails() throws {
        let report = try runComponent(
            [
                (Self.id("group_a"), .required, .matched),
                (Self.id("group_b"), .required, .noMatch),
            ],
            gates: Self.gates()
        )
        #expect(report.hasRequiredFailure)
        #expect(report.results.map(\.outcome) == [.applied, .failed])
    }

    // 7. Ablating a required step → ablated; component not failed.
    @Test func ablatingRequiredStepDoesNotFailComponent() throws {
        let full = Self.id("patchRequired").description
        let report = try runComponent(
            [(Self.id("patchRequired"), .required, .matched)],
            gates: Self.gates(),
            ablate: [full]
        )
        #expect(report.results[0].outcome == .ablated)
        #expect(report.records.isEmpty)      // run intercepted before any bytes written
        #expect(!report.hasRequiredFailure)
    }

    // 8. Unknown ablation id → error before anything runs.
    @Test func unknownAblationIdThrows() throws {
        let pipeline = FirmwarePipeline(
            vmDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), variant: .jb, verbose: false)
        #expect(throws: PatcherError.self) {
            _ = try pipeline.patchAllStructured(ablate: ["does.not.exist"], allowOutput: false)
        }
        // A known component id passes validation and instead fails later (no restore dir).
        do {
            _ = try pipeline.patchAllStructured(ablate: ["avpbooter"], allowOutput: false)
            Issue.record("expected a throw")
        } catch let PatcherError.invalidFormat(msg) {
            Issue.record("known id 'avpbooter' wrongly rejected: \(msg)")
        } catch {
            // Expected: fileNotFound (no *Restore* dir in the temp directory).
        }
    }

    // knownAblationTargets exposes the migrated patchers at all three granularities.
    @Test func knownAblationTargetsCoverMigratedPatchers() {
        let pipeline = FirmwarePipeline(
            vmDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), variant: .jb, verbose: false)
        let targets = pipeline.knownAblationTargets(pipeline.buildComponentList())
        #expect(targets.contains("avpbooter"))
        #expect(targets.contains("avpbooter.AVPBooterPatcher"))
        #expect(targets.contains("avpbooter.AVPBooterPatcher.patchDGSTBypass"))
        #expect(targets.contains("ibss.IBootJBPatcher.patchSkipGenerateNonce"))
        #expect(!targets.contains("does.not.exist"))
    }

    // Report JSON round-trips (PatchID encodes as a dotted string; --report-out path).
    @Test func patchRunReportRoundTripsThroughJSON() throws {
        let gates = Self.gates(iosBaseIs27: true)
        let id = Self.id("patchMacMount", patcher: "KernelJBPatcher", component: "kernelcache")
        let result = PatchResult(
            id: id, requirement: .conditional, rule: .iosBaseIs27,
            outcome: .ablated, reason: "--ablate", recordIndices: [], gates: gates)
        let report = PatchRunReport(
            variant: "jb", gates: gates,
            components: [ComponentReport(component: "kernelcache", coverage: .structured, results: [result], records: [])],
            ablation: [id])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"kernelcache.KernelJBPatcher.patchMacMount\"")) // PatchID as dotted string
        let back = try JSONDecoder().decode(PatchRunReport.self, from: data)
        #expect(back == report)
        #expect(back.isAblationRun)
        #expect(back.failedRequired.isEmpty)
    }

    // 10. Un-migrated (legacy) patcher → coverage legacy; empty ⇒ failed, non-empty ⇒ applied.
    @Test func legacyPatcherCoverageAndSemantics() throws {
        let pipeline = Self.pipeline()

        let (_, emptyReports) = try pipeline.patchDataStructured(
            Data([0x00]), componentName: "legacycomp",
            patcherFactories: [{ data, _ in EmptyLegacyPatcher(data: data) }],
            gates: Self.gates(), ablate: []
        )
        #expect(emptyReports[0].coverage == .legacy)
        #expect(emptyReports[0].results[0].outcome == .failed)
        #expect(emptyReports[0].hasRequiredFailure)

        let (_, okReports) = try pipeline.patchDataStructured(
            Data([0x00, 0x00]), componentName: "test",
            patcherFactories: [{ data, _ in BytePatchPatcher(data: data, offset: 0, byte: 0xAA, id: "legacy") }],
            gates: Self.gates(), ablate: []
        )
        #expect(okReports[0].coverage == .legacy)
        #expect(okReports[0].results[0].outcome == .applied)
        #expect(!okReports[0].hasRequiredFailure)
        #expect(okReports[0].records.map(\.patchID) == ["legacy"])
    }
}

/// A legacy patcher that finds nothing (exercises the "empty ⇒ failed" legacy path).
final class EmptyLegacyPatcher: Patcher {
    let component = "legacycomp"
    let verbose = false
    init(data _: Data) {}
    func findAll() throws -> [PatchRecord] { [] }
    func apply() throws -> Int { 0 }
}

/// Records `save` calls so a dry ablation run can be shown to write nothing.
final class SpyLoader: FirmwarePipeline.FirmwareLoader, @unchecked Sendable {
    let inner: any FirmwarePipeline.FirmwareLoader
    private(set) var saveCount = 0
    init(_ inner: any FirmwarePipeline.FirmwareLoader) { self.inner = inner }
    func load(from url: URL) throws -> Data { try inner.load(from: url) }
    func save(_ data: Data, to url: URL) throws {
        saveCount += 1
        try inner.save(data, to: url)
    }
}

/// C1 alignment: a migrated patcher's declared step methods must line up with the
/// `methods[].name` set for its component in research/firmware_compatibility.json.
struct C1AlignmentTests {
    static func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("research/firmware_compatibility.json").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("could not locate research/firmware_compatibility.json above \(#filePath)")
    }

    /// For the jb configuration, map JSON component name → (methods set, patchers list).
    static func jbComponents() throws -> [String: (methods: [(name: String, required: Bool)], patchers: [String])] {
        let url = repoRoot().appendingPathComponent("research/firmware_compatibility.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let configs = json["patch_configurations"] as! [[String: Any]]
        let jb = configs.first { $0["variant"] as? String == "jb" }!
        var out: [String: (methods: [(name: String, required: Bool)], patchers: [String])] = [:]
        for comp in jb["components"] as! [[String: Any]] {
            let name = comp["component"] as! String
            let methods = (comp["methods"] as! [[String: Any]]).map {
                (name: $0["name"] as! String, required: $0["required"] as? Bool ?? false)
            }
            let patchers = (comp["patchers"] as? [String]) ?? []
            out[name] = (methods, patchers)
        }
        return out
    }

    @Test func avpBooterStepsEqualManifestMethods() throws {
        let comps = try Self.jbComponents()
        let avp = try #require(comps["AVPBooter"])
        let steps = AVPBooterPatcher(data: Data(), verbose: false).buildSteps()
        let stepMethods = Set(steps.map(\.id.method))
        let manifestMethods = Set(avp.methods.map(\.name))
        // AVPBooter is a single-patcher component: exact equality.
        #expect(avp.patchers == ["AVPBooterPatcher"])
        #expect(stepMethods == manifestMethods)
        // Requirement alignment: patchDGSTBypass is required in the manifest.
        #expect(avp.methods.first { $0.name == "patchDGSTBypass" }?.required == true)
        #expect(steps.first { $0.id.method == "patchDGSTBypass" }?.requirement == .required)
    }

    @Test func iBootJBStepsSubsetOfManifestMethods() throws {
        let comps = try Self.jbComponents()
        let ibss = try #require(comps["iBSS"])
        let steps = IBootJBPatcher(data: Data(), mode: .ibss, verbose: false).buildSteps()
        let stepMethods = Set(steps.map(\.id.method))
        let manifestMethods = Set(ibss.methods.map(\.name))
        // iBSS is a multi-patcher component (IBootPatcher + IBootJBPatcher). The
        // migrated IBootJBPatcher owns exactly the methods it declares, which must be
        // a subset of the component's manifest methods.
        #expect(stepMethods.isSubset(of: manifestMethods))
        #expect(stepMethods == ["patchSkipGenerateNonce"])
        #expect(ibss.methods.first { $0.name == "patchSkipGenerateNonce" }?.required == true)
        #expect(steps.first { $0.id.method == "patchSkipGenerateNonce" }?.requirement == .required)
    }
}

/// Unit-level byte parity for the migrated patchers: the pre-C2 `findAll()` and the
/// new structured step path must emit identical `[PatchRecord]` on the same input.
///
/// The signed release binary is SIGKILL'd by the host amfidont daemon, so full
/// CLI-level parity (`patch-firmware --records-out` diff) is not runnable here; this
/// unit-level record equality is the achieved parity proof. When
/// `VPHONE_TEST_AVPBOOTER` / `VPHONE_TEST_IBSS` point at real (already-patched or
/// stock) payloads, parity is checked on real bytes too.
struct MigratedPatcherParityTests {
    @Test func avpBooterFindAllEqualsStepPath_syntheticNoMatch() throws {
        // Garbage input: no DGST constant → both paths yield no records.
        let data = Data(repeating: 0, count: 0x400)
        let oldRecords = (try? AVPBooterPatcher(data: data, verbose: false).findAll()) ?? []
        let new = AVPBooterPatcher(data: data, verbose: false)
        let raw = new.buildSteps()[0].run()
        #expect(raw == .noMatch)
        #expect(oldRecords == new.emittedRecords)
        #expect(new.emittedRecords.isEmpty)
    }

    @Test func avpBooterFindAllEqualsStepPath_realData() throws {
        guard let path = ProcessInfo.processInfo.environment["VPHONE_TEST_AVPBOOTER"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let oldRecords = try AVPBooterPatcher(data: data, verbose: false).findAll()
        let new = AVPBooterPatcher(data: data, verbose: false)
        _ = new.buildSteps()[0].run()
        #expect(oldRecords == new.emittedRecords)
        #expect(!new.emittedRecords.isEmpty)
    }

    @Test func iBootJBFindAllEqualsStepPath_realData() throws {
        guard let path = ProcessInfo.processInfo.environment["VPHONE_TEST_IBSS"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let oldRecords = try IBootJBPatcher(data: data, mode: .ibss, verbose: false).findAll()
        let new = IBootJBPatcher(data: data, mode: .ibss, verbose: false)
        _ = new.buildSteps()[0].run()
        #expect(oldRecords == new.emittedRecords)
    }

    /// Dry ablation run writes nothing. Requires a prepared VM directory via
    /// `VPHONE_TEST_VMDIR` (skipped otherwise so the fast suite stays green).
    @Test func dryAblationRunDoesNotSave() throws {
        guard let dir = ProcessInfo.processInfo.environment["VPHONE_TEST_VMDIR"] else { return }
        let spy = SpyLoader(FirmwarePipeline.ContainerFirmwareLoader())
        let pipeline = FirmwarePipeline(
            vmDirectory: URL(fileURLWithPath: dir), variant: .jb, verbose: false, loader: spy)
        let report = try pipeline.patchAllStructured(ablate: ["avpbooter"], allowOutput: false)
        #expect(report.isAblationRun)
        #expect(!report.ablation.isEmpty)
        #expect(report.failedRequired.isEmpty)   // nothing failed → skip was due to dry
        #expect(spy.saveCount == 0)               // dry run wrote nothing
    }
}

import Capstone
import Foundation

/// Read-only, conservative ARM64 shared-region reveal. The in-image pmap
/// diagnostic identifies the callee; its ABI gives x2=base and x3=size. The
/// ARM64 CPU-type branch and forward data flow establish those argument values.
/// Unsupported layouts refuse rather than infer capacity from a patch name.
enum FirmwareKernelRegion {
    struct Region: Equatable { let base: UInt64; let size: UInt64 }
    static func inspect(_ data: Data) throws -> Region {
        try validateMachO(data)
        let kernel = KernelPatcherBase(data: data, verbose: false)
        kernel.parseMachO()
        guard kernel.codeRanges.allSatisfy({ $0.start >= 0 && $0.end <= data.count && $0.start < $0.end }),
              !kernel.codeRanges.isEmpty else { throw unknown() }
        let anchor = Data("pmap_set_shared_region\0".utf8)
        guard let string = data.range(of: anchor), data.range(of: anchor, in: string.upperBound..<data.count) == nil else { throw unknown() }
        kernel.buildADRPIndex(); kernel.buildBLIndex()
        let d = kernel.disasm
        let references = kernel.findStringRefs(string.lowerBound).filter { pair in
            guard let a = d.disassembleOne(in: data, at: pair.adrpOff), a.mnemonic == "adrp",
                  let b = d.disassembleOne(in: data, at: pair.addOff), b.mnemonic == "add",
                  d.registerName(at: 0, in: a) == d.registerName(at: 1, in: b),
                  b.aarch64?.operands[2].shiftValue == 0,
                  let page = d.immediate(at: 1, in: a), let low = d.immediate(at: 2, in: b) else { return false }
            return page + low == string.lowerBound
        }
        var functions = Set<Int>()
        for ref in references {
            guard let range = kernel.codeRanges.first(where: { ref.adrpOff >= $0.start && ref.addOff < $0.end }) else { continue }
            for offset in stride(from: ref.adrpOff, through: max(range.start, ref.adrpOff - 4096), by: -4) {
                if d.disassembleOne(in: data, at: offset)?.mnemonic == "pacibsp" { functions.insert(offset); break }
            }
        }
        guard functions.count == 1, let pmap = functions.first else { throw unknown() }
        var hits: [Region] = []
        for call in kernel.blIndex[pmap] ?? [] {
            guard let instruction = d.disassembleOne(in: data, at: call), instruction.mnemonic == "bl",
                  d.immediate(at: 0, in: instruction) == Int64(pmap) else { continue }
            guard let range = kernel.codeRanges.first(where: { call >= $0.start && call < $0.end }) else { continue }
            let begin = max(range.start, call - 1024)
            let insns = d.disassemble(in: data, at: begin, count: (call - begin) / 4 + 1)
            // CPU_TYPE_ARM64 is CPU_ARCH_ABI64 | CPU_TYPE_ARM (0x0100000c).
            // Require its complete immediate construction, compare, and unequal
            // branch immediately before entering the candidate case.
            for i in 0..<max(0, insns.count - 4) {
                let a = insns[i], b = insns[i + 1], c = insns[i + 2], branch = insns[i + 3]
                guard ["mov", "movz"].contains(a.mnemonic), d.immediate(at: 1, in: a) == 12,
                      a.aarch64?.operands[1].shiftValue == 0,
                      b.mnemonic == "movk", d.immediate(at: 1, in: b) == 0x100,
                      b.aarch64?.operands[1].shiftValue == 16,
                      b.aarch64?.operands[1].shiftType == AARCH64_SFT_LSL,
                      let reg = d.registerName(at: 0, in: a), reg.hasPrefix("w"),
                      d.registerName(at: 0, in: b) == reg,
                      c.mnemonic == "cmp", d.registerName(at: 1, in: c) == reg,
                      branch.mnemonic == "b.ne", let unequal = d.immediate(at: 0, in: branch),
                      unequal > Int64(branch.address + 4) else { continue }
                if let pair = flow(data, from: Int(branch.address + 4), to: call, excluding: Int(unequal), disasm: d) {
                    hits.append(pair)
                }
            }
        }
        guard hits.count == 1, let result = hits.first, result.base > 0, result.size > 0,
              !result.base.addingReportingOverflow(result.size).overflow else { throw unknown() }
        return result
    }

    static func flow(_ data: Data, from start: Int, to call: Int, excluding: Int,
                             disasm d: ARM64Disassembler) -> Region? {
        var regs: [String: UInt64] = [:], stack: [Int64: (value: UInt64, width: Int64)] = [:]
        var pc = start, seen = Set<Int>()
        func key(_ name: String?) -> String? {
            guard let name else { return nil }
            if name == "xzr" || name == "wzr" { return "zero" }
            if name == "wsp" { return "sp" }
            return name.hasPrefix("w") ? "x" + name.dropFirst() : name
        }
        func value(_ insn: Instruction, _ index: Int) -> UInt64? {
            if let imm = d.immediate(at: index, in: insn) { return UInt64(bitPattern: imm) }
            guard let k = key(d.registerName(at: index, in: insn)) else { return nil }
            return k == "zero" ? 0 : regs[k]
        }
        while pc < call && pc >= start && pc != excluding && seen.insert(pc).inserted && seen.count < 256 {
            guard let insn = d.disassembleOne(in: data, at: pc), insn.size == 4,
                  !(insn.writeback && insn.aarch64?.operands.contains(where: { $0.type == AARCH64_OP_MEM }) == true) else { return nil }
            let dst = key(d.registerName(at: 0, in: insn))
            if dst == "sp" { return nil }
            if insn.mnemonic == "b" {
                guard let target = d.immediate(at: 0, in: insn), target > pc, target <= call else { return nil }
                pc = Int(target); continue
            }
            if KernelPatcherBase.conditionalBranchMnemonics.contains(insn.mnemonic) {
                guard let op = insn.aarch64?.operands.last, op.type == AARCH64_OP_IMM,
                      op.imm > call else { return nil }
            } else if insn.mnemonic == "bl" {
                for n in 0...18 { regs.removeValue(forKey: "x\(n)") }
            } else if ["mov", "movz", "movk"].contains(insn.mnemonic), let dst {
                if insn.mnemonic == "movk" {
                    guard let current = regs[dst], let immediate = d.immediate(at: 1, in: insn),
                          let shift = insn.aarch64?.operands[1].shiftValue, shift < 64,
                          insn.aarch64?.operands[1].shiftType == AARCH64_SFT_LSL || shift == 0 else { return nil }
                    let mask = UInt64(0xffff) << shift
                    regs[dst] = (current & ~mask) | (UInt64(bitPattern: immediate) << shift)
                } else {
                    guard let operand = insn.aarch64?.operands[1], operand.shiftValue == 0,
                          operand.extender == AARCH64_EXT_INVALID else { return nil }
                    regs[dst] = value(insn, 1)
                }
            } else if ["str", "stur", "strb", "strh", "stp"].contains(insn.mnemonic) {
                let memoryIndex = insn.mnemonic == "stp" ? 2 : 1
                guard let operands = insn.aarch64?.operands, operands.count > memoryIndex,
                      operands[memoryIndex].type == AARCH64_OP_MEM else { return nil }
                let memory = operands[memoryIndex].mem
                // Unresolved aliases may overwrite a spill. Refuse after any
                // known spill; only a fixed SP-relative range is understood.
                guard d.memoryBaseRegisterName(at: memoryIndex, in: insn) == "sp",
                      memory.index == AARCH64_REG_INVALID else {
                    if !stack.isEmpty { return nil }; pc += 4; continue
                }
                let name = d.registerName(at: 0, in: insn) ?? ""
                let width: Int64 = insn.mnemonic == "strb" ? 1 : insn.mnemonic == "strh" ? 2 :
                    name.hasPrefix("w") || name.hasPrefix("s") ? 4 : name.hasPrefix("q") ? 16 : 8
                let low = Int64(memory.disp), high = low + width * (insn.mnemonic == "stp" ? 2 : 1)
                for (slot, entry) in stack where slot < high && low < slot + entry.width { stack[slot] = nil }
                if insn.mnemonic == "str", name.hasPrefix("x"), let v = value(insn, 0) {
                    stack[low] = (v, width)
                }
            } else if insn.mnemonic == "ldr", let dst {
                guard let operands = insn.aarch64?.operands, operands.count == 2 else { return nil }
                if d.memoryBaseRegisterName(at: 1, in: insn) == "sp",
                   operands[1].mem.index == AARCH64_REG_INVALID,
                   let entry = stack[Int64(operands[1].mem.disp)], entry.width == 8,
                   d.registerName(at: 0, in: insn)?.hasPrefix("x") == true { regs[dst] = entry.value }
                else { regs[dst] = nil }
            } else if ["add", "sub"].contains(insn.mnemonic), let dst {
                guard dst != "sp", let operands = insn.aarch64?.operands, operands.count == 3,
                      operands[2].shiftValue == 0, operands[2].extender == AARCH64_EXT_INVALID else { return nil }
                if let a = value(insn, 1), let b = value(insn, 2) {
                    let pair = insn.mnemonic == "add" ? a.addingReportingOverflow(b) : a.subtractingReportingOverflow(b)
                    regs[dst] = pair.overflow ? nil : pair.partialValue
                } else { regs[dst] = nil }
            } else if ["orr", "and", "eor", "adrp", "adr", "ldur"].contains(insn.mnemonic), let dst {
                regs[dst] = nil
            } else if !["nop", "cmp", "tst"].contains(insn.mnemonic) {
                return nil
            }
            if let name = d.registerName(at: 0, in: insn), name.hasPrefix("w"), let dst, let v = regs[dst] { regs[dst] = v & 0xffff_ffff }
            pc += 4
        }
        guard pc == call, let base = regs["x2"], let size = regs["x3"] else { return nil }
        return Region(base: base, size: size)
    }
    private static func validateMachO(_ data: Data) throws {
        guard data.count >= 32, data.loadLE(UInt32.self, at: 0) == 0xfeedfacf,
              data.loadLE(UInt32.self, at: 4) == 0x0100000c else { throw unknown() }
        let count = Int(data.loadLE(UInt32.self, at: 16)), bytes = Int(data.loadLE(UInt32.self, at: 20))
        guard bytes <= data.count - 32, count <= bytes / 8 else { throw unknown() }
        var offset = 32
        for _ in 0..<count {
            guard offset <= 32 + bytes - 8 else { throw unknown() }
            let size = Int(data.loadLE(UInt32.self, at: offset + 4))
            guard size >= 8, size <= 32 + bytes - offset else { throw unknown() }
            if data.loadLE(UInt32.self, at: offset) == 0x19 {
                guard size >= 72 else { throw unknown() }
                let sections = Int(data.loadLE(UInt32.self, at: offset + 64))
                let file = data.loadLE(UInt64.self, at: offset + 40)
                let length = data.loadLE(UInt64.self, at: offset + 48)
                guard sections <= (size - 72) / 80, file <= UInt64(data.count),
                      length <= UInt64(data.count) - file else { throw unknown() }
                for index in 0..<sections {
                    let section = offset + 72 + index * 80
                    let sectionSize = data.loadLE(UInt64.self, at: section + 40)
                    let sectionOffset = UInt64(data.loadLE(UInt32.self, at: section + 48))
                    // Zero-fill sections have no file bytes, but Int conversion
                    // in the shared parser must still be representable.
                    guard sectionSize <= UInt64(Int.max) - sectionOffset else { throw unknown() }
                }
            }
            offset += size
        }
        guard offset == 32 + bytes else { throw unknown() }
    }
    private static func unknown() -> FirmwareGeneration.Failure { FirmwareGeneration.fail("Candidate kernel shared-region capacity is unknown or ambiguous") }
}

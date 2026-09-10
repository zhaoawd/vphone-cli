// KernelJBPatchVmProtect.swift — JB kernel patch: VM map protect W^X bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Preserve the EXECUTE bit at the W+X gate. 26.1 keeps the gate in the main
// function; 26.4 places it in an authenticated range-validation callback.
// The separate COW WRITE mask must remain unchanged (see commit 81b0cd8).

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Bypass the vm_map_protect W^X downgrade so write+execute protections are honored.
    @discardableResult
    func patchVmMapProtect() -> RawStepResult {
        log("\n[JB] _vm_map_protect: bypass W^X downgrade")

        // Recover the function from the in-kernel "vm_map_protect(" panic string.
        guard let strOff = buffer.findString("vm_map_protect(") else {
            log("  [-] kernel-text 'vm_map_protect(' anchor not found")
            return .noMatch
        }
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty, let funcStart = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] kernel-text 'vm_map_protect(' anchor not found")
            return .noMatch
        }
        let funcEnd = findFuncEnd(funcStart, maxSize: 0x2000)

        // Shape A: explicit skip branch (26.1 / 26.3). Rewrite `b.ne skip` -> `b skip`.
        let gates = findWriteDowngradeGates(start: funcStart, end: funcEnd)
            + findCallbackExecuteGates(start: funcStart, end: funcEnd)
        if gates.count == 1, let (brOff, target) = gates.first {
            guard let bBytes = encodeB(from: brOff, to: target) else {
                log("  [-] branch rewrite out of range")
                return .encodeFail(reason: "patchVmMapProtect: branch rewrite out of range")
            }
            let delta = target - brOff
            emit(brOff, bBytes,
                 patchID: "kernelcache_jb.vm_map_protect",
                 virtualAddress: fileOffsetToVA(brOff),
                 description: "b #0x\(String(format: "%X", delta)) [_vm_map_protect skip W^X downgrade]")
            return .matched
        }

        // Never fall back to widening the COW WRITE mask.
        log("  [-] expected one vm_map_protect execute gate, found \(gates.count)")
        return gates.count > 1 ? .ambiguous(count: gates.count) : .noMatch
    }

    // MARK: - Shape A (26.1 / 26.3): explicit skip-branch gate

    /// Find the `b.ne` that skips the write-downgrade block, and its target.
    private func findWriteDowngradeGates(start: Int, end: Int) -> [(Int, Int)] {
        let wZrReg: aarch64_reg = AARCH64_REG_WZR

        var hits: [(Int, Int)] = []
        var off = start
        while off + 0x10 < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 4)
            guard insns.count >= 4 else { off += 4; continue }
            let movMask = insns[0], bicsInsn = insns[1], bneInsn = insns[2], tbnzInsn = insns[3]

            // mov wMask, #6
            guard movMask.mnemonic == "mov",
                  let movOps = movMask.aarch64?.operands, movOps.count == 2,
                  movOps[0].type == AARCH64_OP_REG,
                  movOps[1].type == AARCH64_OP_IMM, movOps[1].imm == 6
            else { off += 4; continue }
            let maskReg = movOps[0].reg

            // bics wzr, wMask, wProt
            guard bicsInsn.mnemonic == "bics",
                  let bicsOps = bicsInsn.aarch64?.operands, bicsOps.count == 3,
                  bicsOps[0].type == AARCH64_OP_REG, bicsOps[0].reg == wZrReg,
                  bicsOps[1].type == AARCH64_OP_REG, bicsOps[1].reg == maskReg,
                  bicsOps[2].type == AARCH64_OP_REG
            else { off += 4; continue }
            let protReg = bicsOps[2].reg

            // b.ne <skip>
            guard ["b.ne", "b"].contains(bneInsn.mnemonic),
                  let bneOps = bneInsn.aarch64?.operands, bneOps.count == 1,
                  bneOps[0].type == AARCH64_OP_IMM
            else { off += 4; continue }
            let skipTarget = Int(bneOps[0].imm)
            guard skipTarget > Int(bneInsn.address) else { off += 4; continue }

            // tbnz wEntryFlags, #22, <skip>
            guard tbnzInsn.mnemonic == "tbnz",
                  let tbnzOps = tbnzInsn.aarch64?.operands, tbnzOps.count == 3,
                  tbnzOps[0].type == AARCH64_OP_REG,
                  tbnzOps[1].type == AARCH64_OP_IMM, tbnzOps[1].imm == 22,
                  tbnzOps[2].type == AARCH64_OP_IMM, Int(tbnzOps[2].imm) == skipTarget
            else { off += 4; continue }

            // Verify there's an `and wProt, wProt, #~bit` between tbnz+4 and target.
            let searchStart = Int(tbnzInsn.address) + 4
            let searchEnd = min(skipTarget, end)
            guard findWriteClearBetween(start: searchStart, end: searchEnd, protReg: protReg) != nil
            else { off += 4; continue }

            hits.append((Int(bneInsn.address), skipTarget))
            off += 4
        }

        return hits
    }

    /// Scan [start, end) for `and wProt, wProt, #imm` that strips one of the low protection bits.
    private func findWriteClearBetween(start: Int, end: Int, protReg: aarch64_reg) -> Int? {
        var off = start
        while off < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let insn = insns.first else { off += 4; continue }
            if insn.mnemonic == "and",
               let ops = insn.aarch64?.operands, ops.count == 3,
               ops[0].type == AARCH64_OP_REG, ops[0].reg == protReg,
               ops[1].type == AARCH64_OP_REG, ops[1].reg == protReg,
               ops[2].type == AARCH64_OP_IMM
            {
                let imm = UInt32(bitPattern: Int32(truncatingIfNeeded: ops[2].imm)) & 0xFFFF_FFFF
                // Preserve READ/WRITE and clear EXECUTE.
                if (imm & 0x7) == 0x3 {
                    return off
                }
            }
            off += 4
        }
        return nil
    }

    /// Recover authenticated callback pointers from the anchored vm_map_protect.
    /// Addresses come from decoded ADRP+ADD operands; no per-build offsets.
    private func findCallbackExecuteGates(start: Int, end: Int) -> [(Int, Int)] {
        var hits: [(Int, Int)] = []
        var callbacks = Set<Int>()
        for off in stride(from: start, to: max(start, end - 12), by: 4) {
            guard let va = fileOffsetToVA(off) else { continue }
            let code = disasm.disassemble(in: buffer.data, at: off, count: 4, address: va)
            guard code.count == 4, code[0].mnemonic == "adrp", code[1].mnemonic == "add",
                  code[2].mnemonic == "pacia", code[3].mnemonic == "str",
                  let a = code[0].aarch64?.operands, let b = code[1].aarch64?.operands,
                  let auth = code[2].aarch64?.operands, let store = code[3].aarch64?.operands,
                  a.count == 2, b.count == 3, auth.count == 2, store.count == 2,
                  a[0].type == AARCH64_OP_REG, a[1].type == AARCH64_OP_IMM,
                  b[0].type == AARCH64_OP_REG, b[1].type == AARCH64_OP_REG, b[2].type == AARCH64_OP_IMM,
                  b[0].reg == a[0].reg, b[1].reg == a[0].reg,
                  auth[0].type == AARCH64_OP_REG, auth[0].reg == a[0].reg,
                  store[0].type == AARCH64_OP_REG, store[0].reg == a[0].reg,
                  store[1].type == AARCH64_OP_MEM,
                  store[1].mem.base == AARCH64_REG_SP,
                  let callback = vaToFileOffset(UInt64(bitPattern: a[1].imm &+ b[2].imm)) else { continue }
            callbacks.insert(callback)
        }
        for callback in callbacks {
            guard disasm.disassembleOne(in: buffer.data, at: callback)?.mnemonic == "pacibsp" else { continue }
            let limit = findFuncEnd(callback)
            let body = disasm.disassemble(in: buffer.data, at: callback, count: (limit - callback) / 4)
            for i in body.indices where i + 5 < body.count {
                let seq = Array(body[i...i + 5])
                guard seq.map(\.mnemonic).prefix(5).elementsEqual(["and", "mov", "bic", "cmp", "ccmp"]),
                      ["b.ne", "b"].contains(seq[5].mnemonic),
                      let flag = seq[0].aarch64?.operands,
                      let mask = seq[1].aarch64?.operands,
                      let bic = seq[2].aarch64?.operands,
                      let cmp = seq[3].aarch64?.operands,
                      let ccmp = seq[4].aarch64?.operands,
                      flag.count == 3, mask.count == 2, bic.count == 3, cmp.count == 2, ccmp.count == 3,
                      flag[0].type == AARCH64_OP_REG, flag[1].type == AARCH64_OP_REG,
                      flag[0].reg == flag[1].reg, flag[2].type == AARCH64_OP_IMM, flag[2].imm == 1 << 22,
                      mask[0].type == AARCH64_OP_REG, mask[1].type == AARCH64_OP_IMM, mask[1].imm == 6,
                      bic.allSatisfy({ $0.type == AARCH64_OP_REG }),
                      bic[0].reg == mask[0].reg, bic[1].reg == mask[0].reg,
                      cmp[0].type == AARCH64_OP_REG, cmp[0].reg == mask[0].reg,
                      cmp[1].type == AARCH64_OP_IMM, cmp[1].imm == 0,
                      ccmp[0].type == AARCH64_OP_REG, ccmp[0].reg == flag[0].reg,
                      ccmp[1].type == AARCH64_OP_IMM, ccmp[1].imm == 0,
                      ccmp[2].type == AARCH64_OP_IMM, ccmp[2].imm == 0,
                      seq[4].aarch64?.conditionCode == AArch64CC_EQ,
                      let target = disasm.immediate(at: 0, in: seq[5]),
                      target > Int64(seq[5].address), target < limit,
                      let clear = findWriteClearBetween(start: Int(seq[5].address) + 4, end: Int(target), protReg: bic[2].reg),
                      let write = disasm.disassembleOne(in: buffer.data, at: clear + 4),
                      write.mnemonic == "str", let ops = write.aarch64?.operands,
                      ops.count == 2, ops[0].type == AARCH64_OP_REG, ops[0].reg == bic[2].reg,
                      ops[1].type == AARCH64_OP_MEM else { continue }
                hits.append((Int(seq[5].address), Int(target)))
            }
        }
        return hits
    }

    // MARK: - Shape B (26.5): runtime W^X mask register

    /// Locate the `mov wMask, #5` that defines the W^X protection mask, identified by
    /// the unique `lsr wT, _, #7 ; and wD, wT, wMask` pair that narrows the protection
    /// before pmap_protect_options. Returns (movFileOffset, maskRegIndex).
    private func findWxMaskMov(start: Int, end: Int) -> (Int, UInt32)? {
        var candidates: [(Int, UInt32)] = []
        var off = start
        while off + 8 <= end {
            defer { off += 4 }
            let lsr = buffer.readU32(at: off)
            guard ARM64Inst.isLSRImm7W(lsr) else { continue }
            let wt = ARM64Inst.rd(lsr)
            let and = buffer.readU32(at: off + 4)
            guard ARM64Inst.isANDRegW(and), ARM64Inst.rn(and) == wt else { continue }
            let maskReg = ARM64Inst.rm(and)

            // Find the (unique) `movz wMask, #5` writer in this function.
            var movOff = -1
            var p = start
            while p + 4 <= end {
                let insn = buffer.readU32(at: p)
                if ARM64Inst.isMOVZW(insn), ARM64Inst.rd(insn) == maskReg, ARM64Inst.movImm16(insn) == 5 {
                    if movOff >= 0 { movOff = -2; break } // ambiguous writer
                    movOff = p
                }
                p += 4
            }
            // Dedup by writer offset: several `lsr;and` pairs may reference the same
            // `mov wMask,#5` writer — that is still a single mask, not an ambiguous one.
            if movOff >= 0, !candidates.contains(where: { $0.0 == movOff }) {
                candidates.append((movOff, maskReg))
            }
        }

        return candidates.count == 1 ? candidates[0] : nil
    }
}

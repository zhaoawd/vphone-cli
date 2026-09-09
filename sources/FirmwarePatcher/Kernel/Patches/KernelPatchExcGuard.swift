// KernelPatchExcGuard.swift — Disable EXC_GUARD for Mach port guard violations.
//
// Research kernels enforce Mach port guard violations as fatal EXC_GUARD exceptions.
// Any app calling task_swap_exception_ports() on a guarded port is killed with
// EXC_GUARD. This commonly affects apps that install custom exception handlers.
// Production iOS kernels do not enforce these fatally.
//
// The enforcement path is: guard check → thread_guard_violation() → AST delivery.
// thread_guard_violation stores violation info in the thread struct and triggers an
// AST that delivers the fatal EXC_GUARD exception when the thread returns to userspace.
//
// Patch strategy: find thread_guard_violation via anchor chain and replace its first
// instruction with RET so it returns immediately without recording or delivering
// the violation. This disables ALL Mach port guard violations (acceptable for
// research VMs where guard enforcement is not needed).
//
// Anchor chain:
//   1. "com.apple.security.only-one-exception-port" string
//   2. → ADRP+ADD code ref in set_exception_behavior_allowed() [may be dead code]
//   3. → scan function body for BL to set_exception_behavior_violation()
//   4. → in that target, find BL to thread_guard_violation()
//   5. → patch thread_guard_violation prologue to RET

import Capstone
import Foundation

extension KernelPatcher {
    /// Disable Mach port guard violation enforcement (EXC_GUARD).
    ///
    /// Patches `thread_guard_violation` to return immediately, preventing
    /// all guard violations from being delivered as fatal exceptions.
    @discardableResult
    func patchExcGuardBehavior() -> Bool {
        log("\n[26] exc_guard: disable thread_guard_violation")

        // Step 1: locate the anchor string.
        guard let strOff = buffer.findString("com.apple.security.only-one-exception-port") else {
            log("  [-] anchor string not found")
            return false
        }

        // Step 2: find ADRP+ADD code reference (inside set_exception_behavior_allowed).
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty else {
            log("  [-] no code ref to anchor string")
            return false
        }

        let targets = findLegacyGuardTargets(refs: refs.map(\.addOff))
            .union(findGuardTailCallTargets(refs: refs.map(\.addOff)))
        guard targets.count == 1, let target = targets.first else {
            log("  [-] expected one validated guard AST writer, found \(targets.count)")
            return false
        }
        emit(target, ARM64.ret, patchID: "kernel.thread_guard_violation",
             virtualAddress: fileOffsetToVA(target),
             description: "PACIBSP→RET (disable guard violation delivery)")
        return true
    }

    private func findLegacyGuardTargets(refs: [Int]) -> Set<Int> {
        var targets = Set<Int>()
        for ref in refs {
            guard let start = findFunctionStart(ref) else { continue }
            for call in guardFunctionBody(start) where call.mnemonic == "bl" {
                guard let wrapper = disasm.immediate(at: 0, in: call) else { continue }
                var checked = false
                for insn in guardFunctionBody(Int(wrapper)).prefix(21) {
                    if ["tbz", "tbnz"].contains(insn.mnemonic) { checked = true }
                    if checked, insn.mnemonic == "bl" {
                        if let dest = disasm.immediate(at: 0, in: insn), guardASTWriter(at: Int(dest)) {
                            targets.insert(Int(dest))
                        }
                        break
                    }
                }
            }
        }
        return targets
    }

    /// 26.4 inlines the thid check and calls mach_port_guard_exception(reason: 6).
    /// That wrapper constructs a Mach-port guard code, then tail-calls the AST writer.
    /// Reveal evidence: research/c3_acceptance_diagnosis_2026-09-09.md.
    private func findGuardTailCallTargets(refs: [Int]) -> Set<Int> {
        var candidates = Set<Int>()
        for ref in refs {
            guard let start = findFunctionStart(ref) else { continue }
            let body = guardFunctionBody(start)
            for (index, call) in body.enumerated() where call.mnemonic == "bl" && index > 0 {
                let reason = body[index - 1]
                guard reason.mnemonic == "mov",
                      disasm.registerName(at: 0, in: reason) == "w2",
                      disasm.immediate(at: 1, in: reason) == 6,
                      let wrapper = disasm.immediate(at: 0, in: call) else { continue }
                let wrapperBody = guardFunctionBody(Int(wrapper))
                // Guard type occupies the high bits of argument x1, per mach/port.h.
                guard wrapperBody.contains(where: {
                    $0.mnemonic == "orr" && disasm.registerName(at: 0, in: $0) == "x1"
                        && disasm.immediate(at: 2, in: $0) == 0x2000_0000_0000_0000
                }), let authentication = wrapperBody.lastIndex(where: { $0.mnemonic == "autibsp" }) else { continue }
                for branch in wrapperBody.dropFirst(authentication + 1) where branch.mnemonic == "b" {
                    guard let dest = disasm.immediate(at: 0, in: branch), dest >= 0,
                          !wrapperBody.contains(where: { $0.address == UInt64(dest) }),
                          guardASTWriter(at: Int(dest)) else { continue }
                    candidates.insert(Int(dest))
                }
            }
        }
        return candidates
    }

    private func guardFunctionBody(_ start: Int) -> [Instruction] {
        guard start >= 0, start + 4 <= buffer.count else { return [] }
        let insns = disasm.disassemble(in: buffer.data, at: start,
                                      count: min(512, (buffer.count - start) / 4))
        return Array(insns.prefix(1) + insns.dropFirst().prefix(while: { $0.mnemonic != "pacibsp" }))
    }

    /// Validate argument preservation and code/subcode stores plus AST bit update.
    /// Structure offsets are recovered from operands, never fixed per kernel.
    private func guardASTWriter(at start: Int) -> Bool {
        let body = guardFunctionBody(start)
        guard let first = body.first, first.mnemonic == "pacibsp" || first.mnemonic == "ret" else { return false }
        var saved: [String: aarch64_reg] = [:]
        for insn in body.prefix(16) where insn.mnemonic == "mov" {
            guard let ops = insn.aarch64?.operands, ops.count == 2,
                  ops[0].type == AARCH64_OP_REG,
                  let source = disasm.registerName(at: 1, in: insn),
                  ["x0", "x1", "x2", "x3"].contains(source) else { continue }
            saved[source] = ops[0].reg
        }
        guard let thread = saved["x0"], let code = saved["x1"],
              let subcode = saved["x2"], saved["x3"] != nil else { return false }
        func storeOffset(_ register: aarch64_reg) -> Int64? {
            for insn in body where insn.mnemonic == "str" {
                guard let ops = insn.aarch64?.operands, ops.count == 2,
                      ops[0].type == AARCH64_OP_REG, ops[0].reg == register,
                      ops[1].type == AARCH64_OP_MEM, ops[1].mem.base == thread else { continue }
                return Int64(ops[1].mem.disp)
            }
            return nil
        }
        guard let c = storeOffset(code), let s = storeOffset(subcode), s == c + 8 else { return false }
        // XNU reason.h / exception_types.h: OS_REASON_GUARD=23, EXC_GUARD=12.
        // Both builds load this packed pair and store it into the thread. Require
        // the pair to distinguish other exception writers with similar AST code.
        var guardKind = false
        for insn in body where insn.mnemonic == "adrp" {
            guard let va = fileOffsetToVA(Int(insn.address)) else { continue }
            let seq = disasm.disassemble(in: buffer.data, at: Int(insn.address), count: 3, address: va)
            guard seq.count == 3, seq[1].mnemonic == "ldr", seq[2].mnemonic == "str",
                  let page = seq[0].aarch64?.operands, let load = seq[1].aarch64?.operands,
                  let store = seq[2].aarch64?.operands,
                  page.count == 2, load.count == 2, store.count == 2,
                  page[0].type == AARCH64_OP_REG, page[1].type == AARCH64_OP_IMM,
                  load[0].type == AARCH64_OP_REG, load[1].type == AARCH64_OP_MEM,
                  load[1].mem.base == page[0].reg,
                  disasm.registerName(at: 0, in: seq[1])?.hasPrefix("d") == true,
                  store[0].type == AARCH64_OP_REG, store[0].reg == load[0].reg,
                  store[1].type == AARCH64_OP_MEM, store[1].mem.base == thread,
                  let literal = vaToFileOffset(UInt64(bitPattern: page[1].imm &+ Int64(load[1].mem.disp))),
                  literal >= 0, literal + 8 <= buffer.count else { continue }
            if buffer.readU32(at: literal) == 23, buffer.readU32(at: literal + 4) == 12 {
                guardKind = true
            }
        }
        guard guardKind else { return false }

        for (index, insn) in body.enumerated() where insn.mnemonic == "ldset" && index > 0 {
            let mask = body[index - 1]
            guard mask.mnemonic == "mov", disasm.immediate(at: 1, in: mask) == 0x1000,
                  let m = mask.aarch64?.operands, let atomic = insn.aarch64?.operands,
                  m[0].type == AARCH64_OP_REG, atomic[0].type == AARCH64_OP_REG,
                  m[0].reg == atomic[0].reg else { continue }
            return true
        }
        return false
    }

}

// KernelJBPatchExecPolicyKill.swift — JB kernel patch: neutralize the exec-time
// MAC-verdict (ip_mac_return) security-policy kill.
//
// After the MAC exec hooks run, XNU's exec path (kern_exec.c) checks:
//
//     if (imgp->ip_mac_return != 0) {
//         ... os_reason_create(OS_REASON_EXEC, EXEC_EXIT_REASON_SECURITY_POLICY);
//         error = imgp->ip_mac_return;
//         goto done;                      // SIGKILL the new process at exec
//     }
//
// When running a userland NEWER than the vphone600 kernel (e.g. iOS 27.0 on the
// 26.4 kernel), AMFI's exec hooks reject the newer binaries' code-sign validation
// category, setting ip_mac_return != 0. Every core platform daemon (backboardd,
// cfprefsd, containermanagerd, ...) then dies at exec with
// EXEC_EXIT_REASON_SECURITY_POLICY (namespace 9 / code 0x8), launchd throttles the
// respawns, and the boot deadlocks (all CPUs idle) before SpringBoard/UI.
//
// Flip the `cbz wN, <skip>` guard immediately preceding the reason-create call to
// an unconditional `b <skip>`, so the kill block is unreachable. Safe for
// version-matched userlands too: there ip_mac_return is 0, so the original cbz
// already branches to <skip> — the unconditional b is behaviourally identical.
//
// Anchor (structural, no hardcoded offsets): the
// `os_reason_create(OS_REASON_EXEC=9, EXEC_EXIT_REASON_SECURITY_POLICY=8)` call —
// two adjacent `movz w0,#9 ; movz w1,#8` — preceded by
// `ldr wN,[xM,#imm] ; cbz wN, <forward>`. The ip_mac_return site uses a W-register
// cbz (distinguishing it from the sibling subsystem-root reject site, which cbz's
// an X register).

import Foundation

extension KernelJBPatcher {
    @discardableResult
    func patchExecSecurityPolicyKill() -> Bool {
        log("\n[JB] exec ip_mac_return SECURITY_POLICY kill: cbz -> b (allow)")

        guard let (ks, ke) = kernTextRange else {
            log("  [-] no kernel text range")
            return false
        }

        var hits: [(offset: Int, target: Int)] = []
        var off = ks
        while off + 8 <= ke {
            if let reasonNamespace = disasAt(off),
               reasonNamespace.mnemonic == "mov" || reasonNamespace.mnemonic == "movz",
               disasm.registerName(at: 0, in: reasonNamespace) == "w0",
               disasm.immediate(at: 1, in: reasonNamespace) == 9,
               let reasonCode = disasAt(off + 4),
               reasonCode.mnemonic == "mov" || reasonCode.mnemonic == "movz",
               disasm.registerName(at: 0, in: reasonCode) == "w1",
               disasm.immediate(at: 1, in: reasonCode) == 8
            {
                let cbzOff = off - 4
                let ldrOff = off - 8
                if cbzOff >= ks,
                   let cbz = disasAt(cbzOff), cbz.mnemonic == "cbz",
                   let ldr = disasAt(ldrOff), ldr.mnemonic == "ldr",
                   let cbzRegister = disasm.registerName(at: 0, in: cbz),
                   cbzRegister.hasPrefix("w"),
                   disasm.registerName(at: 0, in: ldr) == cbzRegister,
                   let target = disasm.immediate(at: 1, in: cbz).map(Int.init)
                {
                    // Must be a forward branch that skips the reason-create/kill block.
                    if target > off + 8 {
                        hits.append((cbzOff, target))
                    }
                }
            }
            off += 4
        }

        guard hits.count == 1 else {
            log("  [-] exec ip_mac_return kill guard not found uniquely (found \(hits.count))")
            return false
        }

        let (cbzOff, target) = hits[0]

        guard let bBytes = ARM64Encoder.encodeB(from: cbzOff, to: target) else {
            log("  [-] failed to encode B to 0x\(String(target, radix: 16))")
            return false
        }

        let va = fileOffsetToVA(cbzOff)
        emit(
            cbzOff,
            bBytes,
            patchID: "exec_security_policy_kill",
            virtualAddress: va,
            description: "cbz -> b [exec ip_mac_return SECURITY_POLICY kill bypass]"
        )
        return true
    }
}

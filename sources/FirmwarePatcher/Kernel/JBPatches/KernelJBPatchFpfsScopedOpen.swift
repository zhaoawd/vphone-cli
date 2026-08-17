// KernelJBPatchFpfsScopedOpen.swift — iOS 27 only.
//
// The JB neuters Sandbox vnode_check_open globally so processes can reach /var/jb. But
// FileProvider's fpfs parent-walk needs the stock check to deny at the domain-container
// boundary; without it the walk climbs unbounded and ResolverService balloons → jetsam →
// respring. KernelJBPatchSandboxExtended therefore leaves ops[267] un-neutered on 27, and
// this patch retargets it to a trampoline that runs the real check only for the FileProvider
// daemons (matched by p_comm) and returns allow for everyone else — preserving the bypass.

import Foundation

extension KernelJBPatcher {
    private static let vnodeCheckOpenIndex = 267

    @discardableResult
    func patchFpfsScopedVnodeOpen() -> Bool {
        log("\n[JB] fpfs: scope vnode_check_open to FileProvider daemons")

        guard let opsTable = findSandboxOpsTableFpfs() else {
            log("  [-] sandbox ops table not found"); return false
        }
        let entryOff = opsTable + Self.vnodeCheckOpenIndex * 8
        guard entryOff + 8 <= buffer.count else { return false }
        let entryRaw = buffer.readU64(at: entryOff)
        guard (entryRaw & (1 << 63)) != 0 else {
            log("  [-] ops[267] not the real hook (neutered?): 0x\(String(format: "%016X", entryRaw))"); return false
        }
        let realHookOff = decodeChainedPtr(entryRaw)
        guard realHookOff >= 0, codeRanges.contains(where: { realHookOff >= $0.start && realHookOff < $0.end }) else {
            log("  [-] ops[267] target not in code"); return false
        }

        guard let caveOff = findCodeCave(size: 20 * 4) else { log("  [-] no code cave"); return false }
        guard let caveBytes = buildScopedOpenCave(caveOff: caveOff, realHookOff: realHookOff) else { return false }
        guard let newEntry = encodeAuthRebaseTarget(origVal: entryRaw, targetFoff: caveOff) else { return false }

        emit(entryOff, newEntry, patchID: "jb.fpfs_scoped_open.ops_retarget",
             description: "ops[267] -> FileProvider-scoped vnode_check_open trampoline")
        emit(caveOff, caveBytes, patchID: "jb.fpfs_scoped_open.cave",
             description: "trampoline: FileProvider daemons -> real check, else allow")
        return true
    }

    // vphone600 struct offsets recovered via the kernel gdb stub; cave bytes verified by
    // capstone round-trip. p_comm[0:8] little-endian: "Resolver" = ResolverService,
    // "fileprov" = fileproviderd.
    func buildScopedOpenCave(caveOff: Int, realHookOff: Int) -> Data? {
        func encodeWideConstant(_ halfwords: [UInt16]) -> [Data]? {
            guard halfwords.count == 4,
                  let low = ARM64Encoder.encodeMovzX(rd: 10, imm16: halfwords[0])
            else { return nil }
            var result = [low]
            for index in 1 ..< halfwords.count {
                guard let part = ARM64Encoder.encodeMovkX(
                    rd: 10,
                    imm16: halfwords[index],
                    shift: UInt32(index * 16)
                ) else { return nil }
                result.append(part)
            }
            return result
        }

        let enforceOff = caveOff + 19 * 4
        guard let loadUthread = ARM64Encoder.encodeLdrImmediateX(rt: 8, rn: 8, offset: 0x3F0),
              let loadProc = ARM64Encoder.encodeLdrImmediateX(rt: 8, rn: 8, offset: 0x18),
              let addProcessName = ARM64Encoder.encodeAddImm12(rd: 8, rn: 8, imm12: 0x56C),
              let loadProcessName = ARM64Encoder.encodeLdrImmediateX(rt: 9, rn: 8, offset: 0),
              let resolver = encodeWideConstant([0x6552, 0x6F73, 0x766C, 0x7265]),
              let resolverBranch = ARM64Encoder.encodeBCond(.eq, from: caveOff + 10 * 4, to: enforceOff),
              let fileProvider = encodeWideConstant([0x6966, 0x656C, 0x7270, 0x766F]),
              let fileProviderBranch = ARM64Encoder.encodeBCond(.eq, from: caveOff + 16 * 4, to: enforceOff),
              let realHookBranch = ARM64Encoder.encodeB(from: enforceOff, to: realHookOff)
        else {
            log("  [-] failed to encode FileProvider-scoped trampoline")
            return nil
        }

        var instructions = [
            ARM64Encoder.encodeMrsTpidrEl1(rd: 8),
            loadUthread,
            loadProc,
            addProcessName,
            loadProcessName,
        ]
        instructions.append(contentsOf: resolver)
        instructions.append(ARM64Encoder.encodeCmpRegisterX(rn: 9, rm: 10))
        instructions.append(resolverBranch)
        instructions.append(contentsOf: fileProvider)
        instructions.append(ARM64Encoder.encodeCmpRegisterX(rn: 9, rm: 10))
        instructions.append(fileProviderBranch)
        instructions.append(ARM64Encoder.encodeMovX(rd: 0, rm: 31))
        instructions.append(ARM64.ret)
        instructions.append(realHookBranch)

        guard instructions.count == 20 else {
            log("  [-] cave length drifted: \(instructions.count)")
            return nil
        }
        let data = instructions.reduce(into: Data()) { $0.append($1) }
        guard validateScopedOpenCave(data, caveOff: caveOff, realHookOff: realHookOff) else {
            log("  [-] FileProvider-scoped trampoline failed Capstone validation")
            return nil
        }
        return data
    }

    private func validateScopedOpenCave(_ data: Data, caveOff: Int, realHookOff: Int) -> Bool {
        let instructions = disasm.disassemble(data, at: UInt64(caveOff))
        guard data.count == 80, instructions.count == 20,
              instructions[0].mnemonic == "mrs",
              disasm.registerName(at: 0, in: instructions[0]) == "x8",
              instructions[1].mnemonic == "ldr",
              disasm.memoryBaseRegisterName(at: 1, in: instructions[1]) == "x8",
              instructions[1].aarch64?.operands[1].mem.disp == 0x3F0,
              instructions[2].mnemonic == "ldr",
              instructions[2].aarch64?.operands[1].mem.disp == 0x18,
              instructions[3].mnemonic == "add",
              instructions[4].mnemonic == "ldr",
              instructions[9].mnemonic == "cmp",
              disasm.registerName(at: 0, in: instructions[9]) == "x9",
              disasm.registerName(at: 1, in: instructions[9]) == "x10",
              instructions[10].mnemonic == "b.eq",
              disasm.immediate(at: 0, in: instructions[10]) == Int64(caveOff + 19 * 4),
              instructions[15].mnemonic == "cmp",
              disasm.registerName(at: 0, in: instructions[15]) == "x9",
              disasm.registerName(at: 1, in: instructions[15]) == "x10",
              instructions[16].mnemonic == "b.eq",
              disasm.immediate(at: 0, in: instructions[16]) == Int64(caveOff + 19 * 4),
              instructions[17].mnemonic == "mov",
              disasm.registerName(at: 0, in: instructions[17]) == "x0",
              instructions[18].mnemonic == "ret",
              instructions[19].mnemonic == "b",
              disasm.immediate(at: 0, in: instructions[19]) == Int64(realHookOff)
        else { return false }
        return true
    }

    private func encodeAuthRebaseTarget(origVal: UInt64, targetFoff: Int) -> Data? {
        guard (origVal & (1 << 63)) != 0 else { return nil }
        let v = (origVal & ~UInt64(0xFFFF_FFFF)) | (UInt64(targetFoff) & 0xFFFF_FFFF)
        return withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    private func findSandboxOpsTableFpfs() -> Int? {
        guard let seatbeltOff = buffer.findString("Seatbelt sandbox policy"),
              let pattern = "\u{0}Sandbox\u{0}".data(using: .utf8),
              let range = buffer.data.range(of: pattern) else { return nil }
        let sandboxOff = range.lowerBound + 1
        for seg in segments where (seg.name == "__DATA_CONST" || seg.name == "__DATA") && seg.fileSize > 40 {
            var i = Int(seg.fileOffset); let end = i + Int(seg.fileSize)
            while i <= end - 40 {
                defer { i += 8 }
                let v0 = buffer.readU64(at: i)
                guard v0 != 0, (v0 & (1 << 63)) == 0, (v0 & 0x7FF_FFFF_FFFF) == UInt64(sandboxOff) else { continue }
                let v1 = buffer.readU64(at: i + 8)
                guard (v1 & (1 << 63)) == 0, (v1 & 0x7FF_FFFF_FFFF) == UInt64(seatbeltOff) else { continue }
                let vOps = buffer.readU64(at: i + 32)
                if (vOps & (1 << 63)) == 0 { return Int(vOps & 0x7FF_FFFF_FFFF) }
            }
        }
        return nil
    }
}

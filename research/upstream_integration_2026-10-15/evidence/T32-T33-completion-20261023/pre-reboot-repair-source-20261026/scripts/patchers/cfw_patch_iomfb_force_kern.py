"""Conditional IOMFB kern/virt dispatch for the fixed 24A446 reference layout.

The upstream 8a75092 implementation routes connections with an IOConnect port
through the kern sibling and connections without one through the virt sibling.
The original null-connection branch is preserved. The port field offset 0x14
was verified upstream on 24A446 only; this is not a generic layout detector.

Legacy unconditional branches are diagnosed but never upgraded without trusted
originals/Undo. The production plan gate remains closed pending authenticated
migration and transactional payload/Undo/Receipt publication. This module can
exercise the algorithm on isolated inputs and through a read-only dry-run.
"""

from dataclasses import dataclass
import hashlib
import os
import re
import shutil
import subprocess

from capstone.arm64_const import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG, ARM64_REG_X0, ARM64_REG_W16, ARM64_REG_INVALID

try:
    from .cfw_asm import asm_at, _cs
    from .cfw_dsc_chunks import DSCChunks
    from .cfw_dsc_codesign import reattest_modified_pages, _read_chunk_cd_blob
except ImportError:  # direct execution
    from cfw_asm import asm_at, _cs
    from cfw_dsc_chunks import DSCChunks
    from cfw_dsc_codesign import reattest_modified_pages, _read_chunk_cd_blob


IOMFB = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

# Only this source-backed exception is outside dispatcher rewriting. Unknown
# shapes at other complete public/kern/virt triples are refused, not skipped.
EXCLUDED_OPERATIONS = {"SwapSignal"}
PORT_OFFSET = 0x14  # upstream 24A446 connection layout; not a file/virtual address
REQUIRED = ("SwapBegin", "SwapEnd", "SwapSetLayer")


def _all_symbols(dsc_path, image):
    """Return {symbol_name: vmaddr} for every symbol `ipsw` reports in `image`."""
    ipsw_bin = shutil.which("ipsw")
    if not ipsw_bin:
        raise RuntimeError("`ipsw` not in PATH")
    out = subprocess.run(
        [ipsw_bin, "dyld", "symaddr", dsc_path, "--image", image],
        capture_output=True, text=True, check=True,
    ).stdout
    syms = {}
    for line in out.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line)
        m = re.match(r"\s*(0x[0-9A-Fa-f]+):\s+\([^)]*\)\s+(\S+)", line)
        if m:
            name, address = m.group(2), int(m.group(1), 16)
            if name in syms and syms[name] != address:
                raise ValueError(f"conflicting IOMFB symbol addresses: {name}")
            syms[name] = address
    return syms


def _register(insn, index, register=None):
    return (len(insn.operands) > index and insn.operands[index].type == ARM64_OP_REG
            and (register is None or insn.operands[index].reg == register))


def _target(insn, index):
    if len(insn.operands) > index and insn.operands[index].type == ARM64_OP_IMM:
        return insn.operands[index].imm
    return None


def _load(insn, register=None, displacement=None):
    if (insn.mnemonic != "ldr" or len(insn.operands) != 2 or insn.writeback
            or not _register(insn, 0, register) or insn.operands[1].type != ARM64_OP_MEM):
        return False
    mem = insn.operands[1].mem
    return (mem.base == ARM64_REG_X0 and mem.index == ARM64_REG_INVALID
            and (displacement is None or mem.disp == displacement))


def _original(insns):
    if len(insns) != 4:
        return False
    a, b, c, d = insns
    # The original dispatch pointer must be an X register, not a 32-bit load.
    return (a.mnemonic == "cbz" and _register(a, 0, ARM64_REG_X0)
            and _target(a, 1) is not None and _load(b)
            and b.reg_name(b.operands[0].reg).startswith("x")
            and c.mnemonic == "cbz" and _register(c, 0, b.operands[0].reg)
            and _target(c, 1) == _target(a, 1)
            and d.mnemonic in ("braaz", "br") and len(d.operands) == 1
            and _register(d, 0, b.operands[0].reg))


def _is_dispatch_trampoline(chunks, va):
    return _original(list(_cs.disasm(chunks.bytes_at_vma(va, 16), va)))


def _conditional(insns, kern, virt):
    if len(insns) != 4:
        return False
    a, b, c, d = insns
    return (a.mnemonic == "cbz" and _register(a, 0, ARM64_REG_X0)
            and _target(a, 1) is not None and _load(b, ARM64_REG_W16, PORT_OFFSET)
            and c.mnemonic == "cbnz" and _register(c, 0, ARM64_REG_W16)
            and _target(c, 1) == kern and d.mnemonic == "b" and _target(d, 0) == virt)


def _legacy(insns, kern):
    return bool(insns and insns[0].mnemonic == "b" and _target(insns[0], 0) == kern)


def _mapped(chunks, address, length):
    matches = [(path, offset + address - start, prot) for start, end, offset, prot, path
               in chunks.mappings() if start <= address and address + length <= end]
    if address % 4 or len(matches) != 1 or not matches[0][2] & 4:
        raise ValueError(f"IOMFB span is not uniquely executable: 0x{address:X}+{length}")
    return matches[0][:2]


@dataclass(frozen=True)
class Site:
    name: str
    vma: int
    original: bytes
    replacement: bytes
    state: str


def _plan(chunks, symbols):
    sites = []
    prefix = "_IOMobileFramebufferSwap"
    covered = set()
    for name, address in sorted(symbols.items()):
        if not name.startswith(prefix):
            continue
        suffix = "Swap" + name[len(prefix):]
        kern, virt = symbols.get("_kern_" + suffix), symbols.get("_virt_" + suffix)
        if kern is None:
            continue
        # Inspect all historical public/kern pairs, even those absent from the
        # new conditional set: a prior 31-site patch must not become a partial
        # ten-site migration merely because some virt symbols are missing.
        _mapped(chunks, address, 16)
        raw = chunks.bytes_at_vma(address, 16)
        insns = list(_cs.disasm(raw, address))
        if _legacy(insns, kern):
            raise ValueError(f"{name}: legacy unconditional implementation; trusted Undo required")
        if suffix in EXCLUDED_OPERATIONS:
            print(f"      [=] {name}: source-excluded non-dispatch operation; unchanged")
            continue
        if virt is None:
            continue
        _mapped(chunks, kern, 4)
        _mapped(chunks, virt, 4)
        if kern == virt or any(address <= target < address + 16 for target in (kern, virt)):
            raise ValueError(f"{name}: overlapping dispatcher targets")
        if _conditional(insns, kern, virt):
            state = "current"
        elif _original(insns):
            state = "original"
        else:
            raise ValueError(f"{name}: unknown dispatcher implementation")
        fail = _target(insns[0], 1)
        _mapped(chunks, fail, 4)
        if address <= fail < address + 16 or fail in (kern, virt):
            raise ValueError(f"{name}: invalid null-connection branch")
        replacement = asm_at(
            f"cbz x0, #{fail}; ldr w16, [x0, #{PORT_OFFSET}]; "
            f"cbnz w16, #{kern}; b #{virt}", address)
        decoded = list(_cs.disasm(replacement, address))
        # Keystone can truncate out-of-range immediates: decode all targets.
        if (len(replacement) != 16 or not _conditional(decoded, kern, virt)
                or _target(decoded[0], 1) != fail):
            raise ValueError(f"{name}: conditional branch encoding is out of range")
        if state == "current" and raw != replacement:
            raise ValueError(f"{name}: noncanonical current dispatcher")
        path, offset = _mapped(chunks, address, 16)
        print(f"      [.] {name} ({os.path.basename(path)}+0x{offset:X}): {state}")
        print(f"          {raw.hex()} -> {replacement.hex()}")
        sites.append(Site(name, address, raw, replacement, state))
        covered.add(suffix)
    missing = set(REQUIRED) - covered
    if missing:
        raise ValueError(f"force-kern missing required dispatchers: {sorted(missing)}")
    ordered = sorted(sites, key=lambda site: site.vma)
    if any(a.vma + 16 > b.vma for a, b in zip(ordered, ordered[1:])):
        raise ValueError("overlapping IOMFB dispatcher spans")
    locations = sorted(_mapped(chunks, site.vma, 16) for site in sites)
    if any(a[0] == b[0] and a[1] + 16 > b[1] for a, b in zip(locations, locations[1:])):
        raise ValueError("overlapping IOMFB file spans")
    return sites


def _signature_pages(chunks, sites):
    pages = {}
    metadata = {}
    for site in sites:
        for address in (site.vma, site.vma + 15):
            path, offset = chunks.find_chunk_for_vma(address)
            if path not in metadata:
                metadata[path] = _read_chunk_cd_blob(path)
            meta = metadata[path]
            if meta is None:
                raise ValueError(f"IOMFB chunk has no supported CodeDirectory: {path}")
            size = meta["page_size"]
            index = offset // size
            slot = meta["cd_file_off"] + meta["hash_offset"] + index * 32
            if (size < 16 or meta["cd_file_off"] < meta["code_limit"] or meta["hash_offset"] < 44
                    or index >= meta["n_code_slots"] or (index + 1) * size > meta["code_limit"]
                    or slot + 32 > meta["cd_file_off"] + meta["cd_length"]):
                raise ValueError(f"IOMFB span has no complete signature slot: {path}+0x{offset:X}")
            with open(path, "rb") as stream:
                stream.seek(index * size)
                page = stream.read(size)
                stream.seek(slot)
                digest = stream.read(32)
            if len(page) != size or len(digest) != 32:
                raise ValueError(f"short IOMFB signature page/slot: {path}")
            pages[(path, index)] = (index * size, size, slot)
    return pages


def patch_iomfb_force_kern(chunks_dir, *, dsc_path=None, dry_run=False):
    chunks = DSCChunks(chunks_dir)
    if dsc_path is None:
        dsc_path = os.path.join(chunks_dir, "dyld_shared_cache_arm64e")
    sites = _plan(chunks, _all_symbols(dsc_path, IOMFB))
    pages = _signature_pages(chunks, sites)
    changed = [site for site in sites if site.state == "original"]
    if dry_run:
        print(f"  [DRY RUN] conditional IOMFB: {len(changed)} writes; no migration/publication authority")
        return len(changed)
    # Recheck every classified span before the first write. The caller owns
    # isolation; this check is not a concurrent-writer lock or a transaction.
    for site in sites:
        if chunks.bytes_at_vma(site.vma, 16) != site.original:
            raise ValueError(f"{site.name}: input changed after preflight")
    for site in changed:
        chunks.write_at_vma(site.vma, site.replacement)
    # Both ends matter: a 16-byte dispatcher can cross a signing page boundary.
    # Include current sites to repair interrupted page re-attestation locally.
    reattest_modified_pages(chunks, [address for site in sites
                                    for address in (site.vma, site.vma + 15)])
    for site in sites:
        if chunks.bytes_at_vma(site.vma, 16) != site.replacement:
            raise RuntimeError(f"post-write IOMFB bytes differ at 0x{site.vma:X}")
    for (path, _), (offset, size, slot) in pages.items():
        with open(path, "rb") as stream:
            stream.seek(offset)
            page = stream.read(size)
            stream.seek(slot)
            digest = stream.read(32)
        if len(page) != size or digest != hashlib.sha256(page).digest():
            raise RuntimeError(f"post-write IOMFB page hash differs: {path}+0x{offset:X}")
    print(f"  [+] IOMFB conditional algorithm complete: {len(changed)} written, "
          f"{len(sites) - len(changed)} current; migration/publication not authorized")
    return len(changed)

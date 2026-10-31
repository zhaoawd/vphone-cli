"""Camera-related DSC patches for the vphone EXP firmware.

Two patch families:

1. NeutrinoCore short-circuit — replace the five
   `+[_NUStyleTransfer*Processor processWithInputs:arguments:output:error:]`
   class methods with `mov w0, #0; ret`. Together with the DT `/product/camera`
   node (added by `DeviceTreePatcher.swift`), this lets Camera.app launch and
   reach the viewfinder UI on this VM build without crashing in NeutrinoCore.

2. AVCaptureDevice authorization gate — replace
   `+[AVCaptureDevice authorizationStatusForMediaType:]` in `AVFCapture` with
   `mov w0, #3; ret` (AVAuthorizationStatusAuthorized = 3). Any process that
   probes camera (or any other media type) authorization gets "Authorized"
   without going through TCC. Stage 0 of the vcam stack — makes apps stop
   bailing on the auth check; downstream pipeline still needs Stages 1+2 to
   actually deliver frames.
"""

import hashlib
import os
import re
import shutil
import subprocess
from dataclasses import dataclass

try:
    from .cfw_asm import asm, disasm_at
    from .cfw_dsc_chunks import DSCChunks
    from .cfw_dsc_codesign import _read_chunk_cd_blob, reattest_modified_pages
except ImportError:
    from cfw_asm import asm, disasm_at
    from cfw_dsc_chunks import DSCChunks
    from cfw_dsc_codesign import _read_chunk_cd_blob, reattest_modified_pages


NU_STYLE_TRANSFER_SYMBOLS = [
    "+[_NUStyleTransferProcessor processWithInputs:arguments:output:error:]",
    "+[_NUStyleTransferThumbnailProcessor processWithInputs:arguments:output:error:]",
    "+[_NUStyleTransferApplyProcessor processWithInputs:arguments:output:error:]",
    "+[_NUStyleTransferLearnProcessor processWithInputs:arguments:output:error:]",
    "+[_NUStyleTransferInterpolateProcessor processWithInputs:arguments:output:error:]",
]

AVF_AUTH_STATUS_SYMBOL = (
    "+[AVCaptureDevice authorizationStatusForMediaType:]"
)


def _resolve_symbols_in_image(dsc_path, image_path, wanted_symbols):
    """Resolve a set of ObjC method symbols in `image_path` against `dsc_path`
    via `ipsw dyld symaddr`. Returns {symbol: vmaddr}. Raises if any are missing.
    """
    ipsw_bin = shutil.which("ipsw")
    if not ipsw_bin:
        raise RuntimeError("`ipsw` not in PATH")
    cmd = [
        ipsw_bin, "dyld", "symaddr", dsc_path,
        "--image", image_path,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    wanted = set(wanted_symbols)
    results = {}
    for line in out.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip()
        m = re.match(r"\s*(0x[0-9A-Fa-f]+):\s*\([^)]+\)\s*(.+)$", line)
        if not m:
            continue
        addr, rest = m.group(1), m.group(2)
        sym = rest.rsplit("\t", 1)[0].strip() if "\t" in rest else rest.strip()
        if sym in wanted:
            results[sym] = int(addr, 16)
    missing = [s for s in wanted_symbols if s not in results]
    if missing:
        raise RuntimeError(
            f"could not resolve symbols in {image_path}: {missing}"
        )
    return results


def resolve_nu_symbols(dsc_path):
    """Resolve the five NeutrinoCore symbols."""
    return _resolve_symbols_in_image(
        dsc_path,
        "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore",
        NU_STYLE_TRANSFER_SYMBOLS,
    )


def resolve_avf_auth_symbol(dsc_path):
    """Resolve +[AVCaptureDevice authorizationStatusForMediaType:] in AVFCapture."""
    return _resolve_symbols_in_image(
        dsc_path,
        "/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture",
        [AVF_AUTH_STATUS_SYMBOL],
    )


@dataclass(frozen=True)
class _CameraPatch:
    vma: int
    original: bytes
    replacement: bytes
    state: str


def _plan_camera_patches(chunks, groups, *, force=False):
    """Resolve/read/classify every requested site before any instruction write."""
    plan = []
    mismatches = []
    for vmas, symbols, instructions in groups:
        missing = set(symbols) - vmas.keys()
        if missing:
            raise RuntimeError(f"missing camera symbols: {sorted(missing)}")
        replacement = asm(instructions)
        if len(replacement) != 8:
            raise RuntimeError(f"expected 8 bytes, got {len(replacement)}")
        for sym in sorted(symbols):
            vma = vmas[sym]
            original = chunks.bytes_at_vma(vma, len(replacement))
            if len(original) != len(replacement):
                raise RuntimeError(f"{sym}: short read at 0x{vma:X}")
            loc = chunks.find_chunk_for_vma(vma)
            end = chunks.find_chunk_for_vma(vma + len(replacement) - 1)
            if loc is None or end != (loc[0], loc[1] + len(replacement) - 1):
                raise RuntimeError(f"{sym}: patch crosses a chunk boundary")
            prefix = disasm_at(original, 0, 1)
            if original == replacement:
                state = "already-patched"
            elif prefix and prefix[0].mnemonic == "pacibsp":
                state = "original"
            else:
                state = "mismatch"
                mismatches.append(sym)
            print(f"  {sym} @ 0x{vma:X} ({os.path.basename(loc[0])}+0x{loc[1]:X}): {state}")
            print(f"    {original.hex()} → {replacement.hex()}")
            plan.append(_CameraPatch(vma, original, replacement, state))
    ordered = sorted(plan, key=lambda patch: patch.vma)
    if any(a.vma + len(a.replacement) > b.vma for a, b in zip(ordered, ordered[1:])):
        raise RuntimeError("overlapping camera patch sites")
    if mismatches and not force:
        raise RuntimeError(f"camera prologue not pacibsp: {mismatches}; use --force to override")
    return plan


def _signature_pages(chunks, plan):
    """Require complete SHA-256 page slots before writing any camera site."""
    pages = {}
    metadata = {}
    for patch in plan:
        for vma in (patch.vma, patch.vma + len(patch.replacement) - 1):
            path, offset = chunks.find_chunk_for_vma(vma)
            if path not in metadata:
                metadata[path] = _read_chunk_cd_blob(path)
            meta = metadata[path]
            if meta is None:
                raise RuntimeError(f"camera chunk has no supported CodeDirectory: {path}")
            size = meta["page_size"]
            index = offset // size
            slot = meta["cd_file_off"] + meta["hash_offset"] + index * meta["hash_size"]
            if (index >= meta["n_code_slots"] or (index + 1) * size > meta["code_limit"]
                    or slot + meta["hash_size"] > meta["cd_file_off"] + meta["cd_length"]):
                raise RuntimeError(f"camera page has no complete signature slot: {path}+0x{offset:X}")
            with open(path, "rb") as f:
                f.seek(index * size)
                page = f.read(size)
                f.seek(slot)
                digest = f.read(meta["hash_size"])
            if len(page) != size or len(digest) != meta["hash_size"]:
                raise RuntimeError(f"short read of camera signature page/slot: {path}")
            pages[(path, index)] = (index * size, size, slot)
    return pages


def _apply_camera_plan(chunks, plan, *, dry_run=False):
    if dry_run:
        print("  [DRY RUN]")
        return
    pages = _signature_pages(chunks, plan)
    for patch in plan:
        if patch.state != "already-patched":
            chunks.write_at_vma(patch.vma, patch.replacement)
    # Include existing sites so a rerun can repair hashes after an interrupted
    # write or re-attestation. Both ends cover an eight-byte page-boundary span.
    vmas = [vma for patch in plan for vma in (patch.vma, patch.vma + 7)]
    diags = reattest_modified_pages(chunks, vmas, verbose=True)
    print(f"  re-attested {len(diags)} page(s)")
    for patch in plan:
        if chunks.bytes_at_vma(patch.vma, len(patch.replacement)) != patch.replacement:
            raise RuntimeError(f"post-write verify failed at 0x{patch.vma:X}")
    for (path, _), (offset, size, slot) in pages.items():
        with open(path, "rb") as f:
            f.seek(offset)
            page = f.read(size)
            f.seek(slot)
            actual = f.read(32)
        if len(page) != size or actual != hashlib.sha256(page).digest():
            raise RuntimeError(f"post-write page hash verify failed: {path}+0x{offset:X}")


def patch_nu_styletransfer_short_circuit(chunks, vmas, *, dry_run=False, force=False):
    """Replace the five NeutrinoCore methods with return NO after preflight."""
    plan = _plan_camera_patches(
        chunks, [(vmas, NU_STYLE_TRANSFER_SYMBOLS, "mov w0, #0\nret")], force=force)
    _apply_camera_plan(chunks, plan, dry_run=dry_run)


def patch_avf_authorization_always_authorized(chunks, vmas, *, dry_run=False, force=False):
    """Return Authorized for every media type, retaining the existing scope."""
    plan = _plan_camera_patches(
        chunks, [(vmas, [AVF_AUTH_STATUS_SYMBOL], "mov w0, #3\nret")], force=force)
    _apply_camera_plan(chunks, plan, dry_run=dry_run)


def apply_all_camera_patches(chunks_dir, dsc_path, *, dry_run=False, force=False):
    """Apply every camera DSC patch against `chunks_dir`, resolving symbols
    against `dsc_path`."""
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] DSC: {chunks!r}")

    print(f"  [.] resolving NeutrinoCore symbols against {dsc_path}...")
    nu_vmas = resolve_nu_symbols(dsc_path)
    print(f"  [.] resolving AVFCapture authorization symbol against {dsc_path}...")
    avf_vmas = resolve_avf_auth_symbol(dsc_path)

    plan = _plan_camera_patches(chunks, [
        (nu_vmas, NU_STYLE_TRANSFER_SYMBOLS, "mov w0, #0\nret"),
        (avf_vmas, [AVF_AUTH_STATUS_SYMBOL], "mov w0, #3\nret"),
    ], force=force)
    _apply_camera_plan(chunks, plan, dry_run=dry_run)

    print(f"\n  [+] camera DSC patches applied: 2/2")
    return 2


def apply_avf_auth_only(chunks_dir, dsc_path, *, dry_run=False, force=False):
    """Apply only the AVFCapture authorization gate patch. Useful when running
    on a chunk pulled from a device that already has the NU patches applied
    (composition mode in `vphone-dsc-chunk-ramdisk-deploy`)."""
    chunks = DSCChunks(chunks_dir)
    print(f"  [.] DSC: {chunks!r}")
    print(f"  [.] resolving AVFCapture authorization symbol against {dsc_path}...")
    avf_vmas = resolve_avf_auth_symbol(dsc_path)
    print(f"\n  [1/1] +[AVCaptureDevice authorizationStatusForMediaType:] → return Authorized")
    patch_avf_authorization_always_authorized(chunks, avf_vmas, dry_run=dry_run, force=force)
    print(f"\n  [+] AVF-only camera DSC patch applied: 1/1")
    return 1


def patch_camera_in_dsc(chunks_dir, dsc_path=None):
    """Entry point used by `cfw.py patch-camera-dsc`."""
    if not dsc_path:
        raise RuntimeError("dsc_path is required (pass --dsc-header on the CLI)")
    return apply_all_camera_patches(chunks_dir, dsc_path)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Camera DSC patcher")
    ap.add_argument("chunks_dir", help="directory containing dyld_shared_cache_arm64e.* files")
    ap.add_argument("dsc_header", help="path to the dyld_shared_cache_arm64e header (no suffix)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--avf-only", action="store_true",
                    help="Apply only the AVFCapture authorization gate patch (composition mode)")
    args = ap.parse_args()
    if args.avf_only:
        apply_avf_auth_only(args.chunks_dir, args.dsc_header,
                            dry_run=args.dry_run, force=args.force)
    else:
        apply_all_camera_patches(args.chunks_dir, args.dsc_header,
                                 dry_run=args.dry_run, force=args.force)

"""Clamp the dyld shared cache maxSlide so a large userland cache fits the
PCC vphone600 26.x kernel's fixed 6 GiB shared region.

The vphone600 26.x kernel reserves SHARED_REGION_SIZE_ARM64 = 0x180000000 (6 GiB)
at SHARED_REGION_BASE_ARM64 = 0x180000000 (verified by disassembling the arm64 case
of the kernel's shared_region_create). At map time the kernel needs room for the
cache's mapped span PLUS the cache-header maxSlide (the ASLR range). A newer userland
whose cache nearly fills the region overflows it:

    iOS 27.0 (24A5380h): span 0x17c830000 (~5.95 GiB) + maxSlide 0x20000000 (512 MiB)
                         = 0x19c830000 (~6.46 GiB)  >  0x180000000 (6 GiB)
    iOS 27.0 (24A435):   size 0x17D504000 + maxSlide 0x20000000 = 0x19D504000

-> _shared_region_map_and_slide returns ENOMEM -> dyld cannot map libSystem ->
launchd (pid 1) panics ("initproc failed to start -- Library not loaded:
/usr/lib/libSystem.B.dylib"). Older userlands (e.g. 26.x/18.x) fit with full slide
and are unaffected.

Fix: zero maxSlide in the cache header so the cache maps at slide 0 and fits (iOS 27.0
leaves ~58 MiB spare). Only the main chunk `dyld_shared_cache_arm64e` carries the
dyld_cache_header. maxSlide is a plain metadata field the kernel reads during map
setup, NOT a cs_validate'd dylib code page — so, unlike cfw_patch_iomfb_swapend, NO
page re-attestation is required (confirmed empirically: a live-poked cache with
maxSlide=0 booted with "dyld cache mapped system-wide", 0 panics).

Decision (same as upstream 2.2.3 DyldSharedCacheMaxSlidePatcher.swift): the patcher
itself decides. sharedRegionSize + maxSlide <= region -> no change; maxSlide already
0 -> no change; otherwise zero it. `cfw_install.sh` runs this on a 27.* base only and
never passes --force. force=True (CLI --force) zeroes maxSlide even when the cache
fits; it is for running the verb by hand. The old FORCE_DSC_MAXSLIDE=1 opt-in is
removed (T13a, 2026-10-01).

Before deciding, the header is corroborated the way upstream does it, and any
mismatch raises without writing:
  * a full 0x100-byte header with the "dyld_v1" magic;
  * mappingOffset (dyld's own field-presence gate) reaches past maxSlide;
  * a mapping of the main chunk carries file offset 0 (the header);
  * sharedRegionStart is the lowest mapped address and sharedRegionSize covers the
    whole mapped span, across every chunk's mapping table;
  * sharedRegionSize + maxSlide fits in 64 bits.

dyld_cache_header offsets (little-endian, from dyld's dyld_cache_format.h):
    mappingOffset @0x10 (u32), sharedRegionStart @0xE0, sharedRegionSize @0xE8,
    maxSlide @0xF0
"""

import os
import struct

try:
    from .cfw_dsc_chunks import DSCChunks
except ImportError:
    from cfw_dsc_chunks import DSCChunks

MAIN_CHUNK = "dyld_shared_cache_arm64e"

HEADER_SIZE = 0x100
OFF_MAPPING_OFFSET = 0x10
OFF_SHARED_REGION_START = 0xE0
OFF_SHARED_REGION_SIZE = 0xE8
OFF_MAX_SLIDE = 0xF0

# SHARED_REGION_SIZE_ARM64 baked into the PCC vphone600 26.x kernel. The cache's
# span + maxSlide must fit within this or the shared_region map ENOMEMs.
KERNEL_SHARED_REGION_SIZE = 0x180000000


def _read_header(chunks_dir, main):
    """Return (sharedRegionStart, sharedRegionSize, maxSlide) after the upstream
    header checks. Raises RuntimeError on any mismatch; never writes."""
    with open(main, "rb") as f:
        hdr = f.read(HEADER_SIZE)
    if len(hdr) < HEADER_SIZE:
        raise RuntimeError(f"{MAIN_CHUNK}: header is 0x{len(hdr):X} bytes, need 0x{HEADER_SIZE:X}; "
                           f"not a dyld_cache_header")
    if hdr[:7] != b"dyld_v1":
        raise RuntimeError(f"{main}: not a dyld shared cache (magic={hdr[:16]!r})")

    mapping_offset = struct.unpack_from("<I", hdr, OFF_MAPPING_OFFSET)[0]
    field_end = OFF_MAX_SLIDE + 8
    if mapping_offset < field_end:
        raise RuntimeError(f"{MAIN_CHUNK}: dyld_cache_header ends at 0x{mapping_offset:X}, before "
                           f"maxSlide at 0x{OFF_MAX_SLIDE:X}; this cache version has no maxSlide field")

    try:
        mappings = DSCChunks(chunks_dir).mappings()
    except struct.error as exc:
        raise RuntimeError(f"{chunks_dir}: dyld mapping table unreadable ({exc})") from exc
    if not any(cp == main and file_off == 0 for _start, _end, file_off, _prot, cp in mappings):
        raise RuntimeError(f"{main}: no mapping covers the cache header at file offset 0")

    srstart = struct.unpack_from("<Q", hdr, OFF_SHARED_REGION_START)[0]
    srsize = struct.unpack_from("<Q", hdr, OFF_SHARED_REGION_SIZE)[0]
    maxslide = struct.unpack_from("<Q", hdr, OFF_MAX_SLIDE)[0]

    lowest = min(start for start, _end, _off, _prot, _cp in mappings)
    highest = max(end for _start, end, _off, _prot, _cp in mappings)
    if srstart != lowest:
        raise RuntimeError(f"{MAIN_CHUNK}: sharedRegionStart 0x{srstart:X} is not the cache's lowest "
                           f"mapped address 0x{lowest:X}; the header layout is not the one these "
                           f"offsets describe")
    span = highest - lowest
    if srsize < span:
        raise RuntimeError(f"{MAIN_CHUNK}: sharedRegionSize 0x{srsize:X} is smaller than the 0x{span:X} "
                           f"the cache actually maps; the header layout is not the one these offsets "
                           f"describe")
    return srstart, srsize, maxslide


def patch_dsc_maxslide(chunks_dir, *, kernel_region_size=KERNEL_SHARED_REGION_SIZE, dry_run=False, force=False):
    main = os.path.join(chunks_dir, MAIN_CHUNK)
    if not os.path.isfile(main):
        raise FileNotFoundError(f"main DSC chunk not found: {main}")

    srstart, srsize, maxslide = _read_header(chunks_dir, main)
    print(f"  [.] {MAIN_CHUNK}: start=0x{srstart:X} size=0x{srsize:X} maxSlide=0x{maxslide:X}")

    combined = srsize + maxslide
    if combined >= 1 << 64:
        raise RuntimeError(f"{main}: sharedRegionSize 0x{srsize:X} + maxSlide 0x{maxslide:X} "
                           f"overflows 64 bits; header is not a dyld_cache_header")

    fits = combined <= kernel_region_size
    if fits and not force:
        print(f"      [=] fits: span+maxSlide 0x{combined:X} <= "
              f"region 0x{kernel_region_size:X}; no change")
        return 0
    if maxslide == 0:
        print("      [=] maxSlide already 0; no change")
        return 0

    with open(main, "r+b") as f:
        # Set maxSlide to 0 so the cache maps at slide 0 within the region.
        new_maxslide = 0
        reason = (f"forced: span+maxSlide 0x{combined:X} fits region "
                  f"0x{kernel_region_size:X} but --force set" if fits
                  else f"overflow: span+maxSlide 0x{combined:X} > "
                       f"region 0x{kernel_region_size:X}")
        action = "would set" if dry_run else "set"
        print(f"      [+] {reason}; {action} maxSlide 0x{maxslide:X} -> 0x{new_maxslide:X}")
        if not dry_run:
            f.seek(OFF_MAX_SLIDE)
            f.write(struct.pack("<Q", new_maxslide))
            f.flush()
            os.fsync(f.fileno())
            f.seek(OFF_MAX_SLIDE)
            back = struct.unpack("<Q", f.read(8))[0]
            if back != new_maxslide:
                raise RuntimeError(f"maxSlide write verify failed: 0x{back:X}")

    print("  [+] DSC maxSlide patch complete")
    return 1


def _self_test():
    """Gate logic: a cache that overflows gets clamped; one that fits is untouched.
    Regression coverage lives in tests/test_dsc_maxslide.py."""
    import tempfile

    def mkcache(size, maxslide, path):
        mapping_offset = 0x198
        hdr = bytearray(mapping_offset + 32)
        hdr[0:16] = b"dyld_v1  arm64e\x00"
        struct.pack_into("<II", hdr, OFF_MAPPING_OFFSET, mapping_offset, 1)
        struct.pack_into("<Q", hdr, OFF_SHARED_REGION_START, 0x180000000)
        struct.pack_into("<Q", hdr, OFF_SHARED_REGION_SIZE, size)
        struct.pack_into("<Q", hdr, OFF_MAX_SLIDE, maxslide)
        struct.pack_into("<QQQII", hdr, mapping_offset, 0x180000000, size, 0, 5, 5)
        open(path, "wb").write(hdr)

    with tempfile.TemporaryDirectory() as d:
        c = os.path.join(d, MAIN_CHUNK)
        # overflow (iOS 27.0-like): 0x17c830000 + 0x20000000 > 0x180000000 -> clamp
        mkcache(0x17C830000, 0x20000000, c)
        assert patch_dsc_maxslide(d) == 1
        with open(c, "rb") as f:
            f.seek(OFF_MAX_SLIDE)
            assert struct.unpack("<Q", f.read(8))[0] == 0
        # fits (26.4-like): 0x140904000 + 0x20000000 <= 0x180000000 -> untouched
        mkcache(0x140904000, 0x20000000, c)
        assert patch_dsc_maxslide(d) == 0
        with open(c, "rb") as f:
            f.seek(OFF_MAX_SLIDE)
            assert struct.unpack("<Q", f.read(8))[0] == 0x20000000
        # fits + force (hand use only): zeroes maxSlide even though it fits
        assert patch_dsc_maxslide(d, force=True) == 1
        with open(c, "rb") as f:
            f.seek(OFF_MAX_SLIDE)
            assert struct.unpack("<Q", f.read(8))[0] == 0
        # force + already 0: idempotent no-op
        assert patch_dsc_maxslide(d, force=True) == 0
    print("self-test OK")


if __name__ == "__main__":
    _self_test()

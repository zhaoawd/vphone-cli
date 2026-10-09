#!/usr/bin/env python3
# Offline APFS root-snapshot rename for vphone Disk.img (CFW boot-source flip).
#
# Renames the com.apple.os.update-<hash> system snapshot in place so the
# (seal-enforcement-patched) guest kernel can't find the named root snapshot
# and roots the live volume instead -- the same effect as snaputil in the VM,
# done offline on the host: no mount, no fs_snapshot syscall, no kernel CSR
# gate, no host security change. The name is stored in exactly two b-tree
# records (snap_metadata value + snap_name key), normally in one leaf node;
# a same-length rename keeps name_len and single-snapshot b-tree order intact,
# so only the touched block(s)' fletcher64 change.
#
# Usage: apfs_snap_rename.py <Disk.img> [--dry-run] [--new-prefix PREFIX]
#   Auto-detects the com.apple.os.update-* snapshot; only edits records that
#   live in a valid APFS object block (checksum verified), so identical
#   strings baked into on-volume binaries are never touched.
#
# Scanning (upstream 9a1018bd): the image is read in 64 MiB windows aligned to
# the APFS block size, and only windows holding data are read. A 64 GiB
# Disk.img has far less written; reading its holes returns zeros. SEEK_DATA is
# used only where it is reliable. A decmpfs (UF_COMPRESSED) file answers
# SEEK_DATA and SEEK_HOLE with ENXIO, which reads as "all hole" (T03), and
# HFS+ answers ENOTTY (T15); both fall back to reading every window. The rule
# (holes_reliable) is shared with scripts/cfw_disk_txn.py through
# scripts/sparse_file.py; the app bundle keeps tools/ next to scripts/.
import errno
import os
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
from sparse_file import holes_reliable  # noqa: E402

BS = 4096
OLD_PREFIX = b"com.apple.os.update-"          # 20 bytes
HEXSET = set(b"0123456789abcdefABCDEF")
NAME_LEN = len(OLD_PREFIX) + 64
WINDOW = 64 * 1024 * 1024                      # a multiple of BS


def cksum(block):
    words = struct.unpack('<%dI' % ((BS - 8) // 4), block[8:BS])
    s1 = s2 = 0
    for w in words:
        s1 = (s1 + w) % 0xFFFFFFFF
        s2 = (s2 + s1) % 0xFFFFFFFF
    c1 = 0xFFFFFFFF - ((s1 + s2) % 0xFFFFFFFF)
    c2 = 0xFFFFFFFF - ((s1 + c1) % 0xFFFFFFFF)
    return c1 | (c2 << 32)


def next_data(fd, offset):
    """Offset of the next data at or after offset, None when only hole remains,
    or offset itself when the volume cannot say (that window is read)."""
    try:
        return os.lseek(fd, offset, os.SEEK_DATA)
    except OSError as error:
        if error.errno == errno.ENXIO and (offset > 0 or os.fstat(fd).st_blocks == 0):
            return None
        return offset


def read_exact(fd, count, offset):
    data = os.pread(fd, count, offset)
    if len(data) != count:
        raise OSError(errno.EIO, 'short read at offset %d' % offset)
    return data


def scan(fd, size, stats=None):
    """{block_offset: [(offset_in_block, name), ...]} for every snapshot name
    record in a checksum-valid block. stats, when given, receives the counts of
    windows read and whether holes were skipped."""
    hits = {}
    skip = holes_reliable(fd)
    windows = 0
    offset = 0
    while offset < size:
        if skip:
            data = next_data(fd, offset)
            if data is None:
                break
            if data >= offset + WINDOW:
                offset = data // WINDOW * WINDOW
                continue
        count = min(WINDOW, size - offset)
        window = read_exact(fd, count, offset)
        windows += 1
        i = 0
        while True:
            j = window.find(OLD_PREFIX, i)
            if j < 0:
                break
            i = j + 1
            name = window[j:j + NAME_LEN]
            if len(name) < NAME_LEN:
                # Crosses the window edge: read the rest as the whole-file scan did.
                name = os.pread(fd, NAME_LEN, offset + j)
            hexpart = name[len(OLD_PREFIX):]
            if len(hexpart) < 64 or any(c not in HEXSET for c in hexpart):
                continue                              # not a snapshot name
            within_window = (j // BS) * BS
            block = window[within_window:within_window + BS]
            if len(block) < BS or cksum(block) != struct.unpack('<Q', block[0:8])[0]:
                continue                              # not a valid APFS object block
            hits.setdefault(offset + within_window, []).append((j - within_window, name))
        offset += WINDOW
    if stats is not None:
        stats['windows_read'] = windows
        stats['skipped_holes'] = skip
    return hits


def rename(path, new_prefix=b"orig-fs.disabled.rn-", dry_run=False, log=print, stats=None):
    """Scan, report and (unless dry_run) rewrite. Returns the scan result."""
    if len(new_prefix) != len(OLD_PREFIX):
        raise ValueError("--new-prefix must be exactly %d bytes" % len(OLD_PREFIX))
    fd = os.open(path, os.O_RDONLY if dry_run else os.O_RDWR)
    try:
        hits = scan(fd, os.fstat(fd).st_size, stats)
        if not hits:
            log("no com.apple.os.update-* root snapshot found (already flipped?)")
            return hits
        total = sum(len(v) for v in hits.values())
        name = next(iter(hits.values()))[0][1].decode(errors="replace")
        log("detected snapshot: %s" % name)
        log("records: %d in %d block(s): %s" % (total, len(hits), [hex(b) for b in hits]))
        if dry_run:
            log("[dry-run] would rename prefix -> %s" % new_prefix.decode())
            return hits
        for blk, recs in sorted(hits.items()):
            block = bytearray(read_exact(fd, BS, blk))
            for within, _ in recs:
                assert bytes(block[within:within + len(OLD_PREFIX)]) == OLD_PREFIX
                block[within:within + len(new_prefix)] = new_prefix
            block[0:8] = struct.pack('<Q', cksum(bytes(block)))
            if os.pwrite(fd, bytes(block), blk) != BS:
                raise OSError(errno.EIO, 'short write at offset %d' % blk)
            log("block @0x%x: renamed %d record(s), checksum fixed" % (blk, len(recs)))
        os.fsync(fd)
        log("done: root snapshot renamed -> %s* (VM will boot the live volume)" % new_prefix.decode())
        return hits
    finally:
        os.close(fd)


def main(argv):
    args = list(argv)
    dry = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    new_prefix = b"orig-fs.disabled.rn-"
    if "--new-prefix" in args:
        i = args.index("--new-prefix"); new_prefix = args[i+1].encode(); del args[i:i+2]
    if not args:
        sys.exit("usage: apfs_snap_rename.py <Disk.img> [--dry-run] [--new-prefix PREFIX]")
    if len(new_prefix) != len(OLD_PREFIX):
        sys.exit("--new-prefix must be exactly %d bytes" % len(OLD_PREFIX))
    rename(args[0], new_prefix=new_prefix, dry_run=dry)


if __name__ == "__main__":
    main(sys.argv[1:])

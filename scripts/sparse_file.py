"""Hole-aware reads of large files (Disk.img) that never mistake data for holes.

SEEK_DATA/SEEK_HOLE skip the unwritten parts of a sparse disk image, but not
every file and volume answers them truthfully:

  - a decmpfs file (UF_COMPRESSED; data in the com.apple.decmpfs xattr or the
    resource fork) answers both with ENXIO, which reads as "all hole" (T03);
  - HFS+ answers ENOTTY (T15); other volumes EINVAL or ENOTSUP.

Rule (shared by scripts/cfw_disk_txn.py and tools/apfs_snap_rename.py, T14):
holes are used only when the file is neither UF_COMPRESSED nor SF_DATALESS
and lseek(0, SEEK_HOLE) succeeds. Otherwise every byte is read. When holes are
used, ENXIO from SEEK_DATA means that only hole remains (at offset 0 only when
the file has no allocated blocks); any other error, or an answer outside the
expected range, reads the rest of the file.
"""
import errno
import os
import stat

SF_DATALESS = getattr(stat, 'SF_DATALESS', 0x40000000)


def holes_reliable(fd):
    """Whether SEEK_DATA/SEEK_HOLE describe this file's contents."""
    info = os.fstat(fd)
    if info.st_flags & (stat.UF_COMPRESSED | SF_DATALESS):
        return False
    try:
        os.lseek(fd, 0, os.SEEK_HOLE)
    except OSError:
        # decmpfs: ENXIO; HFS+: ENOTTY; others: EINVAL/ENOTSUP.
        return False
    return True


def data_ranges(fd, size):
    """(start, end) ranges that hold the file's data; holes in between read as zeros.

    The whole file is one range unless holes_reliable(fd). A failed query reads
    from the queried offset to the end of the file.
    """
    if size <= 0:
        return
    if not holes_reliable(fd):
        yield 0, size
        return
    offset = 0
    while offset < size:
        try:
            start = os.lseek(fd, offset, os.SEEK_DATA)
        except OSError as error:
            if error.errno == errno.ENXIO and (offset > 0 or os.fstat(fd).st_blocks == 0):
                return              # only hole after offset
            # Any other error; or "no data at all" for a file with allocated
            # blocks, which is not a hole-only file.
            yield offset, size
            return
        if start >= size:
            return
        if start < offset:
            yield offset, size
            return
        try:
            end = os.lseek(fd, start, os.SEEK_HOLE)
        except OSError:
            yield start, size
            return
        if end <= start:
            yield start, size
            return
        end = min(end, size)
        yield start, end
        offset = end

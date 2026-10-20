#!/usr/bin/env python3
"""Read-only real-source diagnostic; does not grant guest Undo authority."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from cache_systemos import cache_systemos
from patchers.cfw_daemons import parse_cryptex_paths
from patchers import cfw_patch_iomfb_swapend as swap
from patchers.guest_undo import verify_code_pages
from patchers.volume_state import volume_read_only


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('restore', type=Path)
    parser.add_argument('work', type=Path)
    args = parser.parse_args()
    restore, work = args.restore.resolve(), args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    manifest = restore / 'iPhone-BuildManifest.plist'
    relative, _ = parse_cryptex_paths(str(manifest))
    source = restore / relative
    if restore not in source.resolve().parents:
        raise ValueError('SystemOS path outside restore tree')
    source_hash = digest(source)
    image = work / 'SystemOS.dmg'
    # Require a fresh diagnostic cache, never infer its source from existence.
    if image.exists():
        raise ValueError('diagnostic cache already exists; use a new work directory')
    cache_systemos(source, image)
    image_hash = digest(image)
    mount = work / 'readonly'
    mount.mkdir()
    attached = False
    try:
        attachment = subprocess.check_output(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse',
            '-owners', 'on', '-mountpoint', str(mount), '-plist', str(image)])
        attached = True
        (work / 'attachment.plist').write_bytes(attachment)
        info_raw = subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', str(mount)])
        (work / 'volume.plist').write_bytes(info_raw)
        info = plistlib.loads(info_raw)
        if not volume_read_only(info) or info.get('MountPoint') != str(mount):
            raise ValueError('diagnostic mount is not exactly readonly')
        directory = mount / 'System/Library/Caches/com.apple.dyld'
        main_cache = directory / 'dyld_shared_cache_arm64e'
        chunks = swap.DSCChunks(str(directory))
        symbol = swap._resolve_symbol(str(main_cache), swap.IOMFB, swap.SWAPEND_SYMBOL)
        instruction = swap._find_swap_size_insn(swap._disasm_function(chunks, symbol))
        if instruction is None:
            raise ValueError('production SwapEnd semantic anchor not found')
        chunk, offset = chunks.find_chunk_for_vma(instruction.address)
        chunk = Path(chunk)
        before = digest(chunk)
        pages = verify_code_pages(chunk)
        swap.patch_iomfb_swapend(str(directory), target_size=0x560, dry_run=True)
        if digest(chunk) != before:
            raise ValueError('read-only diagnostic changed DSC bytes')
        result = dict(schemaVersion=1, diagnosticOnly=True, runtimeValidated=False,
            source=str(source), sourceSHA256=source_hash, cacheSHA256=image_hash,
            symbol=swap.SWAPEND_SYMBOL, symbolAddress=hex(symbol),
            instructionAddress=hex(instruction.address), member=chunk.name, fileOffset=offset,
            sourceSize=swap._mov_reg_imm(instruction)[1], targetSize=0x560,
            memberSHA256=before, verifiedCodePages=pages, readOnly=True)
        (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    finally:
        if attached:
            subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount)], check=True)
    if digest(source) != source_hash or digest(image) != image_hash:
        raise ValueError('source or diagnostic image changed')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()

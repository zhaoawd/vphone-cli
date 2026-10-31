#!/usr/bin/env python3
"""Throwaway analysis: disassemble iBSS around 'boot-nonce' refs to find the
real generate_nonce gate pattern. Not part of patch logic."""
import sys, glob
from pyimg4 import IM4P
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

paths = glob.glob("vm/**/Firmware/dfu/iBSS.*.im4p", recursive=True)
print("iBSS candidates:", paths)
if not paths:
    sys.exit("no iBSS im4p found")

im4p = IM4P(open(paths[0], "rb").read())
im4p.payload.decompress()
data = im4p.payload.output().data
print("payload size:", len(data))

needle = b"boot-nonce\x00"
str_offs = []
start = 0
while True:
    i = data.find(needle, start)
    if i < 0:
        break
    str_offs.append(i)
    start = i + 1
print("boot-nonce string offsets:", [hex(o) for o in str_offs])

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True

# find ADRP+ADD that resolve (page-aligned base 0) to each str off
add_sites = []
for off in range(0, len(data) - 8, 4):
    a = next(md.disasm(data[off:off+4], off), None)
    b = next(md.disasm(data[off+4:off+8], off+4), None)
    if not a or not b:
        continue
    if a.mnemonic == "adrp" and b.mnemonic == "add":
        try:
            page = a.operands[1].imm
            imm = b.operands[2].imm
        except Exception:
            continue
        if page + imm in str_offs:
            add_sites.append(off + 4)
print("ADRP+ADD ref sites (add offset):", [hex(o) for o in add_sites])

# dump 0x40 bytes forward of each add site
for site in add_sites:
    print(f"\n==== forward disasm from add @ {hex(site)} ====")
    for ins in md.disasm(data[site:site+0x80], site):
        print(f"  {ins.address:#08x}: {ins.mnemonic} {ins.op_str}")

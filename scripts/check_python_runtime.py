#!/usr/bin/env python3
"""Probe native ARM64 assembly/disassembly and the restore Python API."""

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN
from pyimg4 import IM4P
from ipsw_parser.ipsw import IPSW
import pymobiledevice3


def main():
    encoded, count = Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN).asm("mov x0, #1; ret")
    decoded = list(Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN).disasm(bytes(encoded), 0))
    if count != 2 or len(encoded) != 8 or len(decoded) != 2:
        raise RuntimeError("ARM64 assembly/disassembly returned an incomplete result")
    if decoded[0].mnemonic not in ("mov", "movz") or decoded[1].mnemonic != "ret":
        raise RuntimeError("Capstone did not decode the assembled ARM64 instructions")
    if not hasattr(IPSW, "create_from_path"):
        raise RuntimeError("ipsw-parser lacks IPSW.create_from_path")
    print("Python runtime OK: Keystone ARM64 assembly, Capstone disassembly, "
          "pyimg4, pymobiledevice3 and IPSW.create_from_path")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Check isolated audio algorithm provenance; this does not install a HAL driver."""
import json
from pathlib import Path

from check_guest_components import check_sources

ROOT = Path(__file__).resolve().parents[1]


def main():
    pins = json.loads((ROOT / "dependencies/virtio-sound-pins.json").read_text())
    check_sources(pins, ROOT)
    print("VirtIOSound algorithm provenance passed; no deployable audio driver or runtime validation")


if __name__ == "__main__":
    main()

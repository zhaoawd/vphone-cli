#!/usr/bin/env python3
"""Build the uninstalled camera initialization diagnostic candidate."""
import build_t52_camera_candidate as builder

builder.BASE = builder.ROOT / '.build/t52-camera-interface-20261022/package/VPhone.bundle'
builder.BASE_VERSION = '2.6.2-local.93805a71796d'
builder.WORK = builder.ROOT / '.build/t52-camera-diagnostics-20261022'
builder.BUNDLE = builder.WORK / 'package/VPhone.bundle'

if __name__ == '__main__':
    builder.main()

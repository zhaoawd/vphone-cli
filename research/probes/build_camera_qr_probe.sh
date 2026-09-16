#!/bin/zsh
# Builds only; deployment requires a separately reserved test VM.
set -euo pipefail
SCRIPT_DIR="${0:a:h}"
if (( $# != 1 )); then
    print -u2 'usage: zsh build_camera_qr_probe.sh OUTPUT'
    exit 64
fi
probe_output="$1"
if [[ -e "$probe_output" ]]; then
    print -u2 "Output already exists: $probe_output"
    exit 1
fi
xcrun --sdk iphoneos clang \
    -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -arch arm64e -miphoneos-version-min=15.0 -fobjc-arc \
    -framework Foundation -framework AVFoundation -framework CoreImage \
    -framework CoreVideo -framework CoreGraphics -framework ImageIO \
    "$SCRIPT_DIR/camera_qr_probe.m" -o "$probe_output"
ldid -S"$SCRIPT_DIR/camera_qr_probe.entitlements.plist" "$probe_output"
# Fail the build if the signed output cannot expose its entitlements.
ldid -e "$probe_output" | plutil -lint -

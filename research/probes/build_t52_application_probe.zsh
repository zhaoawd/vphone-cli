#!/bin/zsh
# Build only. Guest installation and activation belong to the named acceptance.
set -euo pipefail
probe_script_dir="${0:a:h}"
if (( $# != 1 )); then
    print -u2 'usage: build_t52_application_probe.zsh NEW_OUTPUT_DIRECTORY'
    exit 64
fi
probe_output="$1"
probe_arch="${T52_PROBE_ARCH:-arm64e}"
if [[ "$probe_arch" != arm64 && "$probe_arch" != arm64e ]]; then
    print -u2 'T52_PROBE_ARCH must be arm64 or arm64e'
    exit 64
fi
if [[ -e "$probe_output" ]]; then
    print -u2 "Output already exists: $probe_output"
    exit 1
fi
mkdir "$probe_output"
probe_app="$probe_output/T52Acceptance.app"
mkdir "$probe_app"
/usr/bin/python3 - "$probe_app/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump(dict(CFBundleIdentifier='org.vphone.acceptance.t52.20261022',
        CFBundleExecutable='T52Acceptance', CFBundleName='T52Acceptance',
        CFBundlePackageType='APPL', CFBundleVersion='2', CFBundleShortVersionString='1.0',
        UIApplicationSceneManifest=dict(UIApplicationSupportsMultipleScenes=False),
        MinimumOSVersion='26.0', UIDeviceFamily=[1, 2],
        NSCameraUsageDescription='T52 isolated camera consumer acceptance',
        NSLocationWhenInUseUsageDescription='T52 isolated location consumer acceptance',
        CFBundleURLTypes=[dict(CFBundleURLName='T52Acceptance', CFBundleURLSchemes=['t52acceptance'])]), stream)
PY
xcrun --sdk iphoneos clang -arch "$probe_arch" -miphoneos-version-min=26.0 -Os -fobjc-arc \
    -DT52_CAPTURE_SOURCE_READONLY="${T52_CAPTURE_SOURCE_READONLY:-0}" \
    -DT52_CAPTURE_PROVIDER_QUERY="${T52_CAPTURE_PROVIDER_QUERY:-0}" \
    -DT52_CAPTURE_PROVIDER_FALLBACK_TEST="${T52_CAPTURE_PROVIDER_FALLBACK_TEST:-0}" \
    -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -framework UIKit -framework Foundation -framework AVFoundation -framework CoreLocation -framework CoreGraphics \
    "$probe_script_dir/t52_application_probe.m" -o "$probe_app/T52Acceptance"
/usr/bin/python3 - "$probe_script_dir/camera_qr_probe.entitlements.plist" "$probe_output/entitlements.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    entitlements = plistlib.load(stream)
# Match this formally registered app's data-container identity on every build.
entitlements['com.apple.private.security.container-required'] = 'org.vphone.acceptance.t52.20261022'
with open(sys.argv[2], 'wb') as stream:
    plistlib.dump(entitlements, stream)
PY
codesign --force --sign - --entitlements "$probe_output/entitlements.plist" "$probe_app"
codesign --verify --strict "$probe_app"
plutil -lint "$probe_app/Info.plist"
xcrun vtool -show-build "$probe_app/T52Acceptance"

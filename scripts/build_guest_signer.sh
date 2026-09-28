#!/bin/zsh
# Build the shared signer for the isolated API daemon's iOS target.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
configuration="${1:-Release}"
[[ "$configuration" == Release || "$configuration" == Debug ]] || exit 64
output="$PROJECT_ROOT/.build/daemon-api-v2/signer-$configuration"
mkdir -p "$output"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
sign_sources=("$PROJECT_ROOT"/sources/VPhoneSign/**/*.swift(N))
[[ ${#sign_sources} -gt 0 ]] || exit 1
/usr/bin/xcrun --sdk iphoneos swiftc -O -swift-version 6 -parse-as-library \
  -target arm64-apple-ios15.0 -sdk "$sdk" \
  -emit-library -static -emit-module -module-name VPhoneSign \
  -emit-module-path "$output/VPhoneSign.swiftmodule" \
  -o "$output/libVPhoneSign.a" "${sign_sources[@]}"

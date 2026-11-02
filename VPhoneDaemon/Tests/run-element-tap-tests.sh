#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-element-tap-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx clang -fobjc-arc -framework Foundation -framework CoreGraphics \
    "$daemon/Native/vphoned_element_tap.m" "$daemon/Tests/ElementTapDisplayTests.m" \
    -o "$temporary/element-tap-display-tests"
"$temporary/element-tap-display-tests"

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$temporary/module-cache" \
    "$daemon/Daemon/GuestElementTap.swift" "$daemon/Tests/ElementTapTests.swift" \
    -o "$temporary/element-tap-tests"
"$temporary/element-tap-tests"

# Compile the real RPC dispatch with boundary doubles; no UIKit or guest needed.
for module in IcliKit VphonedNative; do
    case "$module" in
        IcliKit) stub=ElementTapIcliStub.swift; links=() ;;
        VphonedNative) stub=ElementTapNativeStub.swift; links=(-lIcliKit) ;;
    esac
    /usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -emit-library -emit-module \
        -module-cache-path "$temporary/module-cache" -module-name "$module" \
        -I "$temporary" -L "$temporary" $links \
        "$daemon/Tests/$stub" -emit-module-path "$temporary/$module.swiftmodule" \
        -o "$temporary/lib$module.dylib"
done
/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$temporary/module-cache" -I "$temporary" -L "$temporary" \
    -lIcliKit -lVphonedNative -Xlinker -rpath -Xlinker "$temporary" \
    "${VPHONE_ELEMENT_TAP_INPUT:-$daemon/Daemon/GuestAPI+Input.swift}" \
    "$daemon/Daemon/GuestElementTap.swift" "$daemon/Tests/ElementTapAPITests.swift" \
    -o "$temporary/element-tap-api-tests"
"$temporary/element-tap-api-tests"

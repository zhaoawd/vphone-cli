#!/bin/zsh
set -euo pipefail

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-auto-lock-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

# Build the test double for IcliKit
/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -emit-library -emit-module \
    -module-cache-path "$temporary/module-cache" -module-name "IcliKit" \
    -I "$temporary" -L "$temporary" \
    "$daemon/Tests/ElementTapIcliStub.swift" -emit-module-path "$temporary/IcliKit.swiftmodule" \
    -o "$temporary/libIcliKit.dylib"

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$temporary/module-cache" -I "$temporary" -L "$temporary" \
    -lIcliKit -Xlinker -rpath -Xlinker "$temporary" \
    "$daemon/Daemon/GuestLockScreenIdle.swift" \
    "$daemon/Daemon/GuestAPI+AutoLock.swift" \
    "$daemon/Tests/AutoLockTests.swift" \
    -o "$temporary/auto-lock-tests"

"$temporary/auto-lock-tests"

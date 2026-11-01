#!/bin/zsh
set -euo pipefail

tests="${0:a:h}"
root="${tests:h:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-gui-location-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$temporary/module-cache" -enable-testing \
    -emit-library -emit-module -module-name VPhoneCoreKit \
    "$root/VPhoneKit/VPhoneCoreKit/Location/VPhoneSystemLocationController.swift" \
    -o "$temporary/libVPhoneCoreKit.dylib" -emit-module-path "$temporary/VPhoneCoreKit.swiftmodule"

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$temporary/module-cache" -I "$temporary" -L "$temporary" -lVPhoneCoreKit \
    -Xlinker -rpath -Xlinker "$temporary" \
    "$root/VPhoneDaemon/Daemon/GuestOwnedLocation.swift" \
    "$tests/../UI/HostDevices/VPhoneOwnedLocationGuestAdapter.swift" \
    "$tests/../UI/HostDevices/VPhoneLocationProvider.swift" \
    "$tests/../UI/UserInterface/Menu/VPhoneMenuLocation.swift" \
    "$tests/GUILocationSelectionTests.swift" -o "$temporary/gui-location-tests"

"$temporary/gui-location-tests"

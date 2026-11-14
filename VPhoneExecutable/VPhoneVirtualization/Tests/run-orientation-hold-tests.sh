#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
out="$root/.build/orientation-hold-tests"
source="${1:-$root/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift}"
mkdir -p "$out"
# Exercise the production control methods with a fake HTTP transport. The
# AppKit window and the Virtualization socket are outside this test.
awk '
    /^    var interfaceOrientation:/ { capture = 1 }
    /^    \/\/\/ The fold.s settled angle/ { capture = 0 }
    /^    func rotate\(toFirstOf/ { capture = 1 }
    /^    var useGuestTouchInjection:/ { capture = 0 }
    /^    func stop\(\)/ { capture = 1 }
    /^    func sendHIDPress\(/ { capture = 0 }
    capture {
        sub(/@ObservationIgnored /, "")
        sub(/private func probe\(/, "func probe(")
        sub(/private func setDisconnected\(/, "func setDisconnected(")
        print
    }
' "$source" > "$out/control-methods.swiftfrag"

cat "${0:a:h}/OrientationHoldFixture.swiftfrag" "$out/control-methods.swiftfrag" > "$out/OrientationControl.swift"
printf '}\n' >> "$out/OrientationControl.swift"
xcrun --sdk macosx swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$out/module-cache" "$out/OrientationControl.swift" \
    "$root/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneDisplayOrientation.swift" \
    "${0:a:h}/OrientationHoldTests.swift" -o "$out/OrientationHoldTests"
"$out/OrientationHoldTests"

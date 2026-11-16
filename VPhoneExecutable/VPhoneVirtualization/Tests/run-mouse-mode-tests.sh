#!/bin/zsh
set -euo pipefail
tests=${0:a:h}
root=${tests:h:h:h}
out="$root/.build/mouse-mode-tests"
mkdir -p "$out/host-home"
view="$tests:h/UI/VirtualMachine/VPhoneVirtualMachineView.swift"
menu="$tests:h/UI/UserInterface/Menu/VPhoneMenuDevice.swift"
# Compile the real preference, menu action and pointer-policy implementations.
awk '/^enum VPhoneGuestMouseMode:/ {capture=1} capture {print} capture && /^}/ {exit}' "$view" > "$out/mode.swiftfrag"
awk '/^    @objc func setGuestMouseMode\(/ {capture=1} capture {print} capture && /^    }/ {exit}' "$menu" > "$out/menu.swiftfrag"
awk '/^    private var guestPointerFollowsMouse:/ {capture=1} capture {print} capture && /^    }/ {exit}' "$view" > "$out/policy.swiftfrag"
cat "$tests/MouseModeFixture.swiftfrag" "$out/menu.swiftfrag" "$out/policy.swiftfrag" > "$out/MouseModeProduction.swift"
printf '}\n' >> "$out/MouseModeProduction.swift"
cat "$out/mode.swiftfrag" >> "$out/MouseModeProduction.swift"
xcrun --sdk macosx swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$out/module-cache" "$out/MouseModeProduction.swift" \
    "$tests/MouseModeTests.swift" -o "$out/MouseModeTests"
CFFIXED_USER_HOME="$out/host-home" "$out/MouseModeTests"
CFFIXED_USER_HOME="$out/host-home" "$out/MouseModeTests" --expect-touch

#!/bin/zsh
set -euo pipefail
root="${0:a:h:h}"
out="$root/../.build/render-server-lifecycle-tests"
mkdir -p "$out"
xcrun --sdk macosx swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$out/module-cache" \
    "$root/Daemon/GuestRenderServerLifecycle.swift" "$root/Tests/RenderServerLifecycleTests.swift" \
    -o "$out/render-server-lifecycle-tests"
"$out/render-server-lifecycle-tests"

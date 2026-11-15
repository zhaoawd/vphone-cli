#!/bin/zsh
set -euo pipefail
daemon="${0:a:h:h}"
spec="${VPHONE_METHOD_SPEC_SOURCE:-$daemon/Daemon/GuestMethodSpec.swift}"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/vphone-rpc-compat.XXXXXXXX")
trap 'rm -rf "$temporary"' EXIT
sources=("$spec")
if rg -q 'let paged: Paged' "$spec"; then sources+=("$daemon/Daemon/GuestPaging.swift"); fi
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -module-cache-path "$temporary/modules" \
    "${sources[@]}" "$daemon/Tests/RPCCompatibilityTests.swift" -o "$temporary/tests"
"$temporary/tests"

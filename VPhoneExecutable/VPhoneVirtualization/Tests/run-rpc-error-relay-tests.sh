#!/bin/zsh
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
derived="${1:-$root/.build/XcodeBundle}"
packages="${2:-$derived/SourcePackages}"
relay="${3:-$root/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneAPIProxy.swift}"
daemon="${4:-$root/VPhoneDaemon/Daemon/GuestHyperTextHandler.swift}"
products="$derived/Build/Products/Debug"
out="$(mktemp -d "${TMPDIR:-/tmp}/vphone-rpc-error-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

# Test the production handlers with embedded NIO channels. Replace only the
# Virtualization connection held by the relay, and the guest's fallback routes.
{
    printf '%s\n' 'import Foundation' 'import NIOCore' 'final class VZVirtioSocketConnection {}'
    sed -n '/^private final class ByteRelay:/,$p' "$relay" | sed '1s/^private //'
} > "$out/ByteRelay.swift"
awk '/^    func errorCaught\(/ { capture = 1 } capture { print } capture && /^    }/ { exit }' \
    "$daemon" > "$out/upgrade-error.swiftfrag"
{
    cat "${0:a:h}/RPCErrorRelayFixture.swiftfrag"
    cat "$out/upgrade-error.swiftfrag"
    printf '}\n'
} > "$out/UpgradeFallback.swift"

maps=(-I "$packages/checkouts/swift-atomics/Sources/_AtomicsShims/include")
for name in CNIOAtomics CNIODarwin CNIOLinux CNIOWASI CNIOLLHTTP CNIOSHA1; do
    maps+=(-Xcc "-fmodule-map-file=$derived/Build/Intermediates.noindex/GeneratedModuleMaps/$name.modulemap")
done
objects=()
for name in NIOCore NIOEmbedded NIOHTTP1 NIOWebSocket NIOConcurrencyHelpers _NIOBase64 _NIODataStructures CNIOAtomics CNIOLLHTTP CNIOSHA1 CNIODarwin Atomics _AtomicsShims DequeModule InternalCollectionsUtilities; do
    objects+=("$products/$name.o")
done
flags=()
if [[ "${RPC_TEST_LEGACY_RELAY:-0}" == 1 ]]; then
    flags+=(-D LEGACY_RELAY)
fi
xcrun --sdk macosx swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$out/module-cache" -I "$products" "${maps[@]}" "${flags[@]}" \
    "$root/VPhoneKit/VPhoneCoreKit/Support/VPhoneAPIRequestGate.swift" \
    "$out/ByteRelay.swift" "$out/UpgradeFallback.swift" "${0:a:h}/RPCErrorRelayTests.swift" \
    "${objects[@]}" -o "$out/RPCErrorRelayTests"
"$out/RPCErrorRelayTests"

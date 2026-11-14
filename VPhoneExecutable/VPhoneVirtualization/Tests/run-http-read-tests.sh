#!/bin/zsh
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
source="${1:-$root/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift}"
out="$(mktemp -d "${TMPDIR:-/tmp}/vphone-http-read-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

# Use the production reader with local sockets in place of a VSOCK connection.
{
    cat <<'SWIFT'
import Darwin
import Foundation
enum VPhoneGuestControl {
    enum ControlError: Error, Equatable {
        case protocolError(String), notConnected
    }
}
struct HTTPReader {
    static let socketTimeout: Duration = .milliseconds(40)
    let deadline: ContinuousClock.Instant
SWIFT
    awk '
        /^    private func readMore\(/ { capture = 1; sub(/private /, "") }
        capture { print }
        capture && /^}/ { exit }
    ' "$source"
} > "$out/HTTPReader.swift"
xcrun --sdk macosx swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$out/module-cache" "$out/HTTPReader.swift" \
    "${0:a:h}/HTTPReadTests.swift" -o "$out/HTTPReadTests"
"$out/HTTPReadTests"

#!/bin/zsh
# vphone-tier: build
set -euo pipefail

root="$(cd "${0:a:h}/../../.." && pwd)"
out="$root/.build/health-probe-tests"
source="${1:-$root/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift}"
mkdir -p "$out"
# Compile the production request block with a deterministic transport. This
# covers retry admission and propagation, not Virtualization's VSOCK backend.
cat > "$out/Probe.swift" <<'SWIFT'
import Foundation
struct VPhoneHTTPResponse { let status: Int }
enum ProbeFailure: Error { case disconnected }
@MainActor final class Probe {
    var isConnected: Bool
    var replies: [Result<VPhoneHTTPResponse, ProbeFailure>]
    var calls = 0
    init(connected: Bool, replies: [Result<VPhoneHTTPResponse, ProbeFailure>]) {
        isConnected = connected
        self.replies = replies
    }
    func http(method: String, path: String) async throws -> VPhoneHTTPResponse {
        precondition(method == "GET" && path == "/v1/health")
        calls += 1
        precondition(!replies.isEmpty, "unexpected retry")
        return try replies.removeFirst().get()
    }
    func request() async throws -> VPhoneHTTPResponse {
SWIFT
awk '
    /private func probe\(\) async/ { probe = 1; next }
    probe && /let response/ { capture = 1 }
    capture && /guard response.status/ { exit }
    capture { print }
' "$source" >> "$out/Probe.swift"
cat >> "$out/Probe.swift" <<'SWIFT'
        return response
    }
}
SWIFT
xcrun --sdk macosx swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$out/module-cache" "$out/Probe.swift" \
    "${0:a:h}/HealthProbeTests.swift" -o "$out/HealthProbeTests"
"$out/HealthProbeTests"

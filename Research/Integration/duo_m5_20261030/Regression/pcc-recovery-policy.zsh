#!/bin/zsh
set -euo pipefail
root=${0:a:h:h:h:h:h}
regression=${0:a:h}
cd "$root"
out="$root/.build/overall-port-20261116"
products="${VPHONE_PORT_DERIVED_DATA:-$root/.build/duo-sync-20261113/XcodeBundle}/Build/Products/Debug"
mkdir -p "$out/modules"
xcrun swiftc -parse-as-library -O -whole-module-optimization \
    -module-cache-path "$out/modules" -I "$products" \
    -I .build/XcodeRestore/Build/Products/Debug \
    -I VPhoneExecutable/VPhoneCommand/VPhoneRestore/MobileRecoveryCore/Include \
    -I VPhoneExecutable/VPhoneCommand/VPhoneRestore/MobileRestoreCore/Include \
    -F "$products" -Xlinker -dead_strip \
    VPhoneExecutable/VPhoneCommand/VPhoneCommand/Host/VPhonePCCGPURecovery.swift \
    "$regression/PCCRecoveryPolicyRegression.swift" -o "$out/pcc-recovery-policy"
"$out/pcc-recovery-policy"

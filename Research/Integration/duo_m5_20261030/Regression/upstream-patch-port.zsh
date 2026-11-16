#!/bin/zsh
set -euo pipefail
root=${0:a:h:h:h:h:h}
regression=${0:a:h}
cd "$root"
reference=${1:?Original TXM IM4P path required}
fixture=${2:-}
[[ $reference == /* && -f $reference ]]
expected=eda4261548a786998b35f0165d51c05b262727ef4160e7eb1bc4e3c3b9900192
[[ $(shasum -a 256 "$reference" | awk '{print $1}') == $expected ]]
mkdir -p "$root/.build/upstream-port-20261116"
out=$(mktemp -d "$root/.build/upstream-port-20261116/saved-run.XXXXXXXX")
print -r -- "$out"
derived=${VPHONE_PORT_DERIVED_DATA:-$root/.build/duo-sync-20261113/XcodeBundle}
[[ $derived == $root/.build/* ]]
products="$derived/Build/Products/Debug"
# The prior preflight's raw fixture is never needed. Unpack a private copy.
"$products/VPhone.bundle/Contents/MacOS/vphone-cli" fw im4p-extract "$reference" --output "$out/txm-reference.raw" > "$out/extract.log" 2>&1
if [[ -n $fixture ]]; then
    [[ $fixture == /* && -d $fixture/System && -d $fixture/usr ]]
    export TEST_RUNNER_VPHONE_PORT_SYSTEM_ROOT=$fixture
    export TEST_RUNNER_VPHONE_PORT_REPORT_ROOT=$out
fi
export TEST_RUNNER_VPHONE_REMAP_TXM="$out/txm-reference.raw"
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO -jobs 4 test \
    -only-testing:FirmwarePatcherTests/DeviceTreeGuestDeviceTests \
    -only-testing:FirmwarePatcherTests/CustomFirmwareDriverKitTests \
    -only-testing:FirmwarePatcherTests/CustomFirmwareRemotePairingTests \
    -only-testing:FirmwarePatcherTests/FirmwareGuestPatchResolutionTests \
    -only-testing:FirmwarePatcherTests/FirmwarePatchSetCatalogTests \
    -only-testing:FirmwarePatcherTests/FirmwarePatchSelectionCompatibilityTests \
    -only-testing:FirmwarePatcherTests/CustomFirmwareArm64eX1Tests \
    -only-testing:FirmwarePatcherTests/CustomFirmwareArm64eX1InstallationTests \
    -only-testing:FirmwarePatcherTests/CustomFirmwareArm64eX1AuditTests \
    -only-testing:FirmwarePatcherTests/FirmwareAccessibilityPatchTests \
    -only-testing:FirmwarePatcherTests/FirmwareDebugLibraryPatchTests \
    -only-testing:FirmwarePatcherTests/DyldSharedCacheUndoWordsTests \
    -only-testing:FirmwarePatcherTests/TXMExecutableRemapTests \
    -only-testing:FirmwarePatcherTests/TXMMissingProfileTests \
    -only-testing:FirmwarePatcherTests/DuoStandalonePatchArtifactTests > "$out/tests.log" 2>&1
xcrun swiftc -parse-as-library -module-cache-path "$out/modules" \
    -F "$products" -I "$products" -framework VPhonePatchKit \
    -Xlinker -rpath -Xlinker "$products" \
    VPhoneExecutable/VPhoneCommand/FirmwarePatcher/TXM/*.swift \
    "$regression/TXMProductionPolicyRegression.swift" \
    -o "$out/txm-production-probe" > "$out/probe-build.log" 2>&1
"$out/txm-production-probe" "$out" > "$out/txm-policies.log" 2>&1
[[ $(shasum -a 256 "$reference" | awk '{print $1}') == $expected ]]
cat "$out/txm-policies.log"

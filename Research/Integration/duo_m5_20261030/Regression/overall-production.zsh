#!/bin/zsh
set -euo pipefail
root=${0:a:h:h:h:h:h}
cd "$root"
regression=${0:a:h}
derived=${VPHONE_PORT_DERIVED_DATA:-$root/.build/duo-sync-20261113/XcodeBundle}
mkdir -p "$root/.build/overall-port-20261116"
out=$(mktemp -d "$root/.build/overall-port-20261116/saved-run.XXXXXXXX")
print -r -- "$out"

xcodebuild -project VPhoneKit/VPhoneKit.xcodeproj -scheme VPhoneCoreKitTests \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO -jobs 4 test \
    -only-testing:VPhoneCoreKitTests/PCCCryptexctlTests \
    -only-testing:VPhoneCoreKitTests/PCCGPUDriverTests \
    -only-testing:VPhoneCoreKitTests/FirmwareCatalogReportTests \
    -only-testing:VPhoneCoreKitTests/GuestDeviceTests > "$out/core-tests.log" 2>&1
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO -jobs 4 test \
    -only-testing:FirmwarePatcherTests/DeviceTreeGuestDeviceTests \
    -only-testing:FirmwarePatcherTests/SPTMSecondaryCPUTests \
    -only-testing:FirmwarePatcherTests/CryptexTrustedDarwinOSTests \
    -only-testing:FirmwarePatcherTests/TrustCacheTests \
    -only-testing:FirmwarePatcherTests/FirmwareManifestSelectionTests \
    -only-testing:FirmwarePatcherTests/FirmwarePatchSetCatalogTests \
    -only-testing:FirmwarePatcherTests/FirmwareGuestPatchResolutionTests \
    -only-testing:FirmwarePatcherTests/FirmwarePatchSelectionCompatibilityTests \
    -only-testing:FirmwarePatcherTests/FirmwarePatchDriftTests \
    -only-testing:FirmwarePatcherTests/DyldSharedCacheQuartzCoreUnrotatedFramebufferTests \
    -only-testing:FirmwarePatcherTests/DyldSharedCacheUndoLogTests \
    -only-testing:FirmwarePatcherTests/DyldSharedCacheUndoWordsTests \
    > "$out/patcher-tests.log" 2>&1
make -C VPhoneGuestComponents OUT="$out/guest-tests" test-ios18-gpu > "$out/transport-tests.log" 2>&1
zsh "$regression/pcc-recovery-policy.zsh" > "$out/pcc-policy-tests.log" 2>&1
zsh VPhoneDaemon/Tests/run-methods-tests.sh > "$out/methods-tests.log" 2>&1
zsh VPhoneDaemon/Tests/run-process-output-tests.sh > "$out/process-output-tests.log" 2>&1
zsh VPhoneLaunchpad/Tests/BundleNamesTests.sh > "$out/version-contract-tests.log" 2>&1

xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
    -disableAutomaticPackageResolution -jobs 4 build > "$out/bundle-build.log" 2>&1
bundle="$derived/Build/Products/Debug/VPhone.bundle"
codesign --verify --deep --strict "$bundle" > "$out/signature.log" 2>&1
"$bundle/Contents/MacOS/vphone-cli" fw patches --json > "$out/catalog.json"
"$bundle/Contents/MacOS/vphone-cli" cfw patch-quartzcore-unrotated-framebuffer --help > "$out/framebuffer-help.txt"
node "$regression/test-patch-selection-cli.mjs" "$bundle/Contents/MacOS/vphone-cli" "$out/selection-cli" > "$out/selection-cli.log" 2>&1
[[ -z $(git ls-files '*.py') ]]
print -r -- "Overall production regression passed: $out"

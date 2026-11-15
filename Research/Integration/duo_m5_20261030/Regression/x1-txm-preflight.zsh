#!/bin/zsh
set -euo pipefail
root=${0:a:h:h:h:h:h}
regression=${0:a:h}
cd "$root"
reference=${1:?Original TXM IM4P path required}
[[ $reference == /* && -f $reference ]]
expected=eda4261548a786998b35f0165d51c05b262727ef4160e7eb1bc4e3c3b9900192
[[ $(shasum -a 256 "$reference" | awk '{print $1}') == $expected ]] || {
    print -u2 'Reference does not match the measured TXM container'; exit 1
}
mkdir -p "$root/.build/x1-txm-preflight-20261115"
out=$(mktemp -d "$root/.build/x1-txm-preflight-20261115/saved-run.XXXXXXXX")
print -r -- "$out"
revision=1316940501398ea279f960ee7d838f93885730d4
derived=${VPHONE_X1_TXM_DERIVED_DATA:-$root/.build/duo-sync-20261113/XcodeBundle}
[[ $derived == $root/.build/* ]]
products="$derived/Build/Products/Debug"
mkdir -p "$out/upstream-txm"
for name in TXMPatcher TXMDevPatcher TXMExecutableRemap TXMMissingProfile; do
    git show "$revision:VPhoneExecutable/VPhoneCommand/FirmwarePatcher/TXM/$name.swift" > "$out/upstream-txm/$name.swift"
done
node --input-type=module - "$revision" "$out" <<'JS'
import fs from 'node:fs';import {execFileSync} from 'node:child_process';
const [revision,out]=process.argv.slice(2);
const source=execFileSync('git',['show',revision+':VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwareGuestSystemPatchSet.swift'],{encoding:'utf8'});
const table=source.slice(source.indexOf('public static let arm64eX1AccessibilityImages:'),source.indexOf('public static let arm64eX1OptionalImages'));
const images=[...table.matchAll(/\("(system-[^"]+)", "([^"]+)"\)/g)].map(([,identifier,name])=>({identifier,path:'System/Library/AccessibilityBundles/'+name+'.axbundle/'+name}));
if(images.length!==35)throw Error('Pinned upstream inventory changed');
fs.writeFileSync(out+'/upstream-accessibility.json',JSON.stringify({revision,images},null,2)+'\n');
JS
TEST_RUNNER_VPHONE_X1_TXM_PREFLIGHT_DIR="$out" \
TEST_RUNNER_VPHONE_X1_TXM_PREFLIGHT_TXM="$reference" \
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO -jobs 4 test \
    -only-testing:FirmwarePatcherTests/FirmwareX1TXMSyncPreflightTests \
    -only-testing:FirmwarePatcherTests/CustomFirmwareArm64eX1Tests \
    -only-testing:FirmwarePatcherTests/DyldSharedCacheUndoWordsTests \
    -only-testing:FirmwarePatcherTests/FirmwarePatchSetCatalogTests > "$out/current-tests.log" 2>&1
xcrun swiftc -parse-as-library -module-cache-path "$out/modules" \
    -F "$products" -I "$products" -framework VPhonePatchKit \
    -Xlinker -rpath -Xlinker "$products" \
    "$out/upstream-txm/"*.swift "$regression/TXMUpstreamPolicyPreflight.swift" \
    -o "$out/upstream-txm-probe" > "$out/upstream-probe-build.log" 2>&1
"$out/upstream-txm-probe" "$out" > "$out/upstream-policy-run.log" 2>&1
cat "$out/upstream-policy-run.log"
[[ $(shasum -a 256 "$reference" | awk '{print $1}') == $expected ]]
print 'Reference container unchanged; source, reports and logs retained in the printed directory'

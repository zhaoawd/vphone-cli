#!/bin/zsh
set -euo pipefail
source_dir=${0:a:h}
repo_root=${source_dir:h:h:h:h:h}
output=${1:?Absolute new output directory required}
signer=${2:?Built vphone-cli path required}
[[ $output == "$repo_root"/.build/* && ! -e $output && -x $signer ]]
app="$output/Payload/RemapProbe.app"
framework="$app/Frameworks/RemapFixture.framework"
mkdir -p "$framework" "$output/external"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
target=(-target arm64-apple-ios26.0 -isysroot "$sdk")
xcrun --sdk iphoneos clang "${target[@]}" -O2 -Wall -Wextra -Werror -dynamiclib \
    -DMARKER_NAME=remap_framework_marker -DMARKER_VALUE=57 "$source_dir/marker.c" \
    -install_name @rpath/RemapFixture.framework/RemapFixture -o "$framework/RemapFixture"
cat > "$framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vphone.tests.remap-fixture</string><key>CFBundleExecutable</key><string>RemapFixture</string><key>CFBundleName</key><string>RemapFixture</string><key>CFBundleVersion</key><string>1</string><key>CFBundlePackageType</key><string>FMWK</string>
</dict></plist>
PLIST
xcrun --sdk iphoneos clang "${target[@]}" -O2 -Wall -Wextra -fobjc-arc -fblocks \
    -DMARKER_NAME=remap_main_marker -DMARKER_VALUE=42 "$source_dir/main.m" "$source_dir/marker.c" \
    -F "$app/Frameworks" -framework RemapFixture -framework UIKit -framework Foundation \
    -Wl,-rpath,@executable_path/Frameworks -o "$app/RemapProbe"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vphone.tests.remap-probe</string><key>CFBundleExecutable</key><string>RemapProbe</string><key>CFBundleName</key><string>RemapProbe</string><key>CFBundleDisplayName</key><string>RemapProbe</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundlePackageType</key><string>APPL</string><key>LSRequiresIPhoneOS</key><true/><key>MinimumOSVersion</key><string>26.0</string><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/><key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array><dict><key>UISceneConfigurationName</key><string>Probe</string><key>UISceneDelegateClassName</key><string>RemapProbeSceneDelegate</string></dict></array></dict></dict>
</dict></plist>
PLIST
cat > "$output/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>application-identifier</key><string>com.vphone.tests.remap-probe</string><key>get-task-allow</key><true/></dict></plist>
PLIST
codesign --force --sign - "$framework"
codesign --force --sign - --entitlements "$output/entitlements.plist" "$app"
codesign --verify --deep --strict "$app"
xcrun --sdk iphoneos clang "${target[@]}" -O2 -Wall -Wextra -Werror -dynamiclib "$source_dir/injected.c" \
    -install_name @rpath/libinjected.dylib -o "$output/external/libinjected-adhoc.dylib"
codesign --force --sign - "$output/external/libinjected-adhoc.dylib"
cp "$output/external/libinjected-adhoc.dylib" "$output/external/libinjected-ldid.dylib"
"$signer" sign "$output/external/libinjected-ldid.dylib"
xcrun --sdk iphoneos clang "${target[@]}" -O2 -Wall -Wextra -Werror "$source_dir/standalone.c" -o "$output/external/standalone-adhoc"
codesign --force --sign - "$output/external/standalone-adhoc"
cp "$output/external/standalone-adhoc" "$output/external/standalone-ldid"
"$signer" sign "$output/external/standalone-ldid"
(cd "$output" && ditto -c -k --norsrc --noextattr --keepParent Payload RemapProbe.ipa)
shasum -a 256 "$output/RemapProbe.ipa" "$output"/external/* > "$output/sha256.txt"
print -r -- "$output"

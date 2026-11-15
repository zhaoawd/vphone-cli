#!/bin/zsh
set -euo pipefail
source_dir=${0:a:h}
output=${1:?Absolute output directory required}
[[ $output == /* ]]
app="$output/CameraWebProbe.app"
mkdir -p "$app"
xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -fobjc-arc -fblocks -O1 -Wno-nullability-completeness -Wno-incompatible-pointer-types \
    -framework CoreGraphics -framework UIKit -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Foundation \
    "$source_dir/main.m" -o "$app/CameraWebProbe"
cp "$source_dir/index.html" "$app/index.html"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vphone.tests.camera-web</string><key>CFBundleExecutable</key><string>CameraWebProbe</string><key>CFBundleName</key><string>Camera Regression</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.vphone.tests.camera-web</string><key>CFBundleURLSchemes</key><array><string>vphone-camera-probe</string></array></dict></array><key>LSRequiresIPhoneOS</key><true/><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>UILaunchScreen</key><dict/><key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/><key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array><dict><key>UISceneConfigurationName</key><string>Probe</string><key>UISceneDelegateClassName</key><string>ProbeScene</string></dict></array></dict></dict><key>NSCameraUsageDescription</key><string>Validate synthetic camera frames in the isolated test VM.</string><key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$app"
mkdir -p "$output/Payload"
cp -R "$app" "$output/Payload/"
(cd "$output" && /usr/bin/zip -qr CameraWebProbe.ipa Payload)

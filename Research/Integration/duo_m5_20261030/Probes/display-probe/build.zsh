#!/bin/zsh
set -euo pipefail
source_dir=${0:a:h}
root=${source_dir:h:h:h:h:h}
out=${1:?new absolute output directory required}
[[ $out == "$root/.build/"* && ! -e $out ]]
app="$out/Payload/DisplayProbe.app"
mkdir -p "$app"
xcrun --sdk iphoneos clang -O2 -Wall -Wextra -Wno-unused-parameter -Werror -target arm64-apple-ios27.1 -fobjc-arc \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore "$source_dir/main.m" -o "$app/DisplayProbe"
cp "$source_dir/../tap-probe/Info.plist" "$app/Info.plist"
plutil -replace CFBundleIdentifier -string com.vphone.tests.display-probe "$app/Info.plist"
for key in CFBundleExecutable CFBundleName CFBundleDisplayName; do plutil -replace "$key" -string DisplayProbe "$app/Info.plist"; done
plutil -replace UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneDelegateClassName -string DisplayProbeScene "$app/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
(cd "$out" && ditto -c -k --norsrc --noextattr --keepParent Payload DisplayProbe.ipa)
shasum -a 256 "$out/DisplayProbe.ipa" > "$out/sha256.txt"

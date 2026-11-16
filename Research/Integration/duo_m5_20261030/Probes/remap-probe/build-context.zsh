#!/bin/zsh
set -euo pipefail
source_dir=${0:a:h}
output=${1:?New output directory required}
signer=${2:?Built vphone-cli required}
zsh "$source_dir/build.zsh" "$output" "$signer"
app="$output/Payload/RemapProbe.app"
identity=com.vphone.tests.remap-context
plutil -replace CFBundleIdentifier -string "$identity" "$app/Info.plist"
plutil -replace CFBundleDisplayName -string RemapContext "$app/Info.plist"
cat > "$output/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>application-identifier</key><string>$identity</string>
<key>get-task-allow</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.private.security.no-container</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --entitlements "$output/entitlements.plist" "$app"
codesign --verify --deep --strict "$app"
(cd "$output" && ditto -c -k --norsrc --noextattr --keepParent Payload RemapContext.ipa)
shasum -a 256 "$output/RemapContext.ipa" > "$output/context-sha256.txt"

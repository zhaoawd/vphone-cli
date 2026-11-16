#!/bin/zsh
set -euo pipefail
source_dir=${0:a:h}
repo_root=${source_dir:h:h:h:h:h}
output=${1:?New absolute output directory required}
policy=${2:-plain}
[[ $policy == plain || $policy == dynamic ]]
[[ $output == "$repo_root"/.build/* && ! -e $output ]]
mkdir -p "$output"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun clang -target arm64-apple-ios26.0 -isysroot "$sdk" -g -O1 -Wall -Wextra -Werror \
    "$source_dir/mutation.c" "$source_dir/mutation.S" -o "$output/MutationProbe"
cat > "$output/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>get-task-allow</key><true/>
<key>com.apple.private.security.no-container</key><true/>
</dict></plist>
PLIST
if [[ $policy == dynamic ]]; then
    plutil -insert dynamic-codesigning -bool YES "$output/entitlements.plist"
fi
codesign --force --sign - --entitlements "$output/entitlements.plist" "$output/MutationProbe"
codesign --verify --strict "$output/MutationProbe"
xcrun dwarfdump --uuid "$output/MutationProbe" > "$output/uuid.txt"
shasum -a 256 "$output/MutationProbe" > "$output/sha256.txt"

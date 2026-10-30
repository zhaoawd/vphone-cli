#!/bin/zsh
# Build native probes only. Does not install, launch, or contact any VM.
set -euo pipefail

source_root="${0:a:h}"
repo_root="$(cd "$source_root/../../../.." && pwd)"
probe_platform="${1:?usage: build.zsh <device|sim> [new-output-directory]}"
output_root="${2:-$repo_root/.build/validation/probes/$probe_platform-$(uuidgen)}"
case "$probe_platform" in
    device) probe_sdk=iphoneos; probe_target=arm64-apple-ios27.1; platform_name=iPhoneOS ;;
    sim) probe_sdk=iphonesimulator; probe_target=arm64-apple-ios27.1-simulator; platform_name=iPhoneSimulator ;;
    *) print -u2 'Expected device or sim'; exit 2 ;;
esac
[[ ! -e "$output_root" ]] || { print -u2 "Output directory must be new: $output_root"; exit 1; }
mkdir -p "$output_root"

build_app() {
    local name="$1" bundle_id="$2" component="$3" plist="$4" full_screen="$5"; shift 5
    local app_root="$output_root/$name/Payload/$name.app"
    mkdir -p "$app_root"
    xcrun --sdk "$probe_sdk" clang -O2 -target "$probe_target" -fobjc-arc \
        -framework UIKit -framework Foundation -framework CoreGraphics \
        -o "$app_root/$name" "$@"
    cp "$source_root/$component/$plist" "$app_root/Info.plist"
    for key in CFBundleExecutable CFBundleName CFBundleDisplayName; do
        plutil -replace "$key" -string "$name" "$app_root/Info.plist"
    done
    plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_root/Info.plist"
    plutil -replace CFBundleSupportedPlatforms -json "[\"$platform_name\"]" "$app_root/Info.plist"
    plutil -replace MinimumOSVersion -string 27.1 "$app_root/Info.plist"
    plutil -replace UIRequiresFullScreen -bool "$full_screen" "$app_root/Info.plist"
    print -rn -- 'APPL????' > "$app_root/PkgInfo"
    if [[ "$probe_platform" == device ]]; then
        local entitlements="$output_root/$name/entitlements.plist"
        /usr/libexec/PlistBuddy -c 'Clear dict' "$entitlements" >/dev/null
        /usr/libexec/PlistBuddy -c "Add :application-identifier string $bundle_id" \
            -c 'Add :get-task-allow bool true' "$entitlements"
        codesign --force --sign - --entitlements "$entitlements" "$app_root"
        (cd "$output_root/$name" && ditto -c -k --norsrc --noextattr --keepParent Payload "$name.ipa")
    else
        codesign --force --sign - "$app_root"
    fi
    codesign --verify --strict "$app_root"
    print "Built: $app_root"
}

build_app GeoProbe com.autophone.geoprobe geo-probe Info.plist false "$source_root/geo-probe/main.m"
build_app GeoBare com.autophone.geobare geo-probe Info.plist false -DGEO_BARE "$source_root/geo-probe/main.m"
build_app KBProbe com.autophone.kbprobe kb-probe Info.plist false "$source_root/kb-probe/main.m"
build_app KBProbeFS com.autophone.kbprobe.fs kb-probe Info.plist true "$source_root/kb-probe/main.m"
build_app Probe com.autophone.probe cssc-probe app/Info.plist false \
    "$source_root/cssc-probe/app/main.m" "$source_root/cssc-probe/cssc_probe.c"
xcrun --sdk macosx clang -O2 -arch arm64 -o "$output_root/cssc-host" \
    "$source_root/cssc-probe/host_main.c" "$source_root/cssc-probe/cssc_probe.c"
print "Probe outputs: $output_root"

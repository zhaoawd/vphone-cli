#!/bin/zsh
# Isolated upstream API daemon build. Does not install, bundle, launch or activate it.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
output="${VPHONE_DAEMON_API_BUILD_DIR:-$PROJECT_ROOT/.build/daemon-api-v2}"
package_cache="$output/PackageCache"
mkdir -p "$package_cache"
project="$PROJECT_ROOT/sources/VPhoneDaemon/VPhoneDaemon.xcodeproj"
python3 "$SCRIPT_DIR/check_daemon_api.py"
if [[ ! -d "$output/Xcode/SourcePackages/checkouts/icli/.git" ]]; then
  xcodebuild -resolvePackageDependencies -project "$project" -scheme vphoned \
    -derivedDataPath "$output/Xcode" -packageCachePath "$package_cache" -onlyUsePackageVersionsFromResolvedFile
fi
python3 "$SCRIPT_DIR/daemon_api_overlays.py" --checkouts "$output/Xcode/SourcePackages/checkouts"
python3 "$SCRIPT_DIR/check_daemon_api.py" --checkouts "$output/Xcode/SourcePackages/checkouts"
overlay_sha=$(python3 "$SCRIPT_DIR/daemon_api_overlays.py" --fingerprint)
xcodebuild -project "$project" -scheme vphoned -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$output/Xcode" \
  -packageCachePath "$package_cache" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -jobs 4 CODE_SIGNING_ALLOWED=NO \
  "GCC_PREPROCESSOR_DEFINITIONS=\$(inherited) VP_DAEMON_OVERLAY_SHA=\\\"${overlay_sha}\\\"" build
python3 "$SCRIPT_DIR/check_daemon_api.py" --checkouts "$output/Xcode/SourcePackages/checkouts"
for profile in classic v2; do
  stage="$output/candidate"
  plist=vphoned.plist
  if [[ "$profile" == v2 ]]; then
    stage="$output/candidate-v2"
    plist=vphoned-api.plist
  fi
  mkdir -p "$stage"
  cp "$output/Xcode/Build/Products/Release-iphoneos/vphoned" "$stage/vphoned"
  cp "$PROJECT_ROOT/sources/VPhoneDaemon/Configuration/$plist" "$stage/$plist"
  cp "$PROJECT_ROOT/sources/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements" "$stage/vphoned.entitlements.plist"
  ldid -S"$stage/vphoned.entitlements.plist" -M "-K$SCRIPT_DIR/vphoned/signcert.p12" "$stage/vphoned"
  python3 "$SCRIPT_DIR/check_daemon_api.py" --candidate "$stage" --record
  print -r -- "Candidate only: $stage (not installed or activated)"
done

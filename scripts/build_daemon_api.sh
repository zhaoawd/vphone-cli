#!/bin/zsh
# Isolated upstream API daemon build. Does not install, bundle, launch or activate it.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
output="$PROJECT_ROOT/.build/daemon-api-v2"
project="$PROJECT_ROOT/sources/VPhoneDaemon/VPhoneDaemon.xcodeproj"
python3 "$SCRIPT_DIR/check_daemon_api.py"
xcodebuild -project "$project" -scheme vphoned -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$output/Xcode" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -jobs 4 CODE_SIGNING_ALLOWED=NO build
python3 "$SCRIPT_DIR/check_daemon_api.py" --checkouts "$output/Xcode/SourcePackages/checkouts"
stage="$output/candidate"
mkdir -p "$stage"
cp "$output/Xcode/Build/Products/Release-iphoneos/vphoned" "$stage/vphoned"
cp "$PROJECT_ROOT/sources/VPhoneDaemon/Configuration/vphoned.plist" "$stage/vphoned.plist"
cp "$PROJECT_ROOT/sources/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements" "$stage/vphoned.entitlements.plist"
ldid -S"$stage/vphoned.entitlements.plist" -M "-K$SCRIPT_DIR/vphoned/signcert.p12" "$stage/vphoned"
python3 "$SCRIPT_DIR/check_daemon_api.py" --candidate "$stage" --record
print -r -- "Candidate only: $stage (not installed or activated)"

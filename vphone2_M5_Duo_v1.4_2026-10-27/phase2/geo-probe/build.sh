#!/bin/zsh
# Build one GeoProbe variant from main.m:
#   build.sh sim|device          GeoProbe (mode B, navigation container), com.autophone.geoprobe
#   build.sh sim|device bare     GeoBare  (mode A, no container),         com.autophone.geobare
# sim: arm64 iphonesimulator. device: arm64 iphoneos, ad hoc signed with
# application-identifier for installd. Output: build/<platform>/<Name>.app,
# and build/device/<Name>.ipa.
set -euo pipefail
D=${0:a:h}
P=${1:?sim or device}
V=${2:-}
case $P in
  sim)    SDK=iphonesimulator; TARGET=arm64-apple-ios27.1-simulator; PLATFORM=iPhoneSimulator ;;
  device) SDK=iphoneos;        TARGET=arm64-apple-ios27.1;           PLATFORM=iPhoneOS ;;
  *) print -u2 "sim or device"; exit 2 ;;
esac
if [[ $V == bare ]]; then NAME=GeoBare; BID=com.autophone.geobare; DEFS=(-DGEO_BARE)
else NAME=GeoProbe; BID=com.autophone.geoprobe; DEFS=(); fi
OUT=$D/build/$P
A=$OUT/$NAME.app
rm -rf $A $OUT/Payload-$NAME $OUT/$NAME.ipa && mkdir -p $A
xcrun -sdk $SDK clang -O2 -target $TARGET -fobjc-arc $DEFS -framework UIKit -framework Foundation -framework CoreGraphics \
  -o $A/$NAME $D/main.m
cp $D/Info.plist $A/Info.plist
plutil -replace CFBundleSupportedPlatforms -json "[\"$PLATFORM\"]" $A/Info.plist
plutil -replace CFBundleExecutable -string $NAME $A/Info.plist
plutil -replace CFBundleName -string $NAME $A/Info.plist
plutil -replace CFBundleDisplayName -string $NAME $A/Info.plist
plutil -replace CFBundleIdentifier -string $BID $A/Info.plist
plutil -replace MinimumOSVersion -string 27.1 $A/Info.plist
plutil -replace DTSDKName -string "$SDK$(xcrun -sdk $SDK --show-sdk-version)" $A/Info.plist
plutil -convert binary1 $A/Info.plist
print -rn -- 'APPL????' > $A/PkgInfo
if [[ $P == device ]]; then
  sed "s/com.autophone.geoprobe/$BID/" $D/ent.plist > $OUT/$NAME.ent
  codesign -f -s - --entitlements $OUT/$NAME.ent $A
  mkdir -p $OUT/Payload-$NAME/Payload && cp -R $A $OUT/Payload-$NAME/Payload/
  (cd $OUT/Payload-$NAME && ditto -c -k --norsrc --noextattr --keepParent Payload ../$NAME.ipa)
else
  codesign -f -s - $A
fi
print -r -- "built $A ($BID)"

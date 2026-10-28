#!/bin/zsh
# Run GeoProbe (mode B) and GeoBare (mode A) on the "GeoProbe Duo" simulator in
# whatever fold state and orientation Device Hub has it in, and save each app's
# samples (geometry-<n>.json), a screenshot and the runtime build under
# run/phase2/geo-<tag>/<App>/.
#   run-sim.sh <tag> [App ...]
set -euo pipefail
D=${0:a:h}
TAG=${1:?tag}; shift
APPS=(${=@:-GeoProbe GeoBare})
OUT=/Users/kolar/vphone-duo-m5/run/phase2/geo-$TAG
NAME="GeoProbe Duo"
mkdir -p $OUT
UDID=$(xcrun simctl list devices -j | jq -r --arg n "$NAME" '[.devices[][] | select(.name == $n)][0].udid // empty')
if [[ -z $UDID ]]; then
  UDID=$(xcrun simctl create "$NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-Duo com.apple.CoreSimulator.SimRuntime.iOS-27-1)
fi
xcrun simctl bootstatus $UDID -b > /dev/null
xcrun simctl list runtimes -j | jq -c '[.runtimes[] | select(.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-1") | {name, buildversion, version}][0]' > $OUT/runtime.json
print -r -- "simulator $UDID runtime $(cat $OUT/runtime.json)"
for APP in $APPS; do
  BID=$([[ $APP == GeoBare ]] && print com.autophone.geobare || print com.autophone.geoprobe)
  mkdir -p $OUT/$APP
  xcrun simctl install $UDID $D/build/sim/$APP.app
  xcrun simctl terminate $UDID $BID > /dev/null 2>&1 || true
  C=$(xcrun simctl get_app_container $UDID $BID data)
  rm -f $C/Documents/geometry*.json(N)
  xcrun simctl launch $UDID $BID > /dev/null
  sleep 5
  cp $C/Documents/geometry*.json(N) $OUT/$APP/
  xcrun simctl io $UDID screenshot $OUT/$APP/screen.png > /dev/null 2>&1
  xcrun simctl terminate $UDID $BID > /dev/null 2>&1 || true
  print -r -- "$APP: $( print -l $OUT/$APP/geometry-*.json(N) | wc -l | tr -d ' ') samples"
done

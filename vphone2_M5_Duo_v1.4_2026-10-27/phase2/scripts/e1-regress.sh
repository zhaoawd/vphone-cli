#!/bin/zsh
# E1 regression with the inner cutout correction on (or off, for comparison):
# landscape, drag, cancel, background/foreground, lock/unlock, Safari. Expects
# the VM stopped; ends stopped.
#   e1-regress.sh on|off
# Boot 1 sets the flags, boot 2 is a cold boot at 2007x2853. GeoBare's window
# event log (phase per touch: 0 began, 1 moved, 3 ended, 4 cancelled) is the
# criterion for app delivery; screenshots are kept for the visual checks.
set -uo pipefail
STATE=${1:?on|off}
CUTOUT="399 30 37 37"
R=/Users/kolar/vphone-duo-m5/run/phase2
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
U=0000FE01-EE96AF93EAD0FBC8
O=$R/e1-regress/$STATE
BID=com.autophone.geobare
FIX_FLAG=/var/mobile/Library/Caches/vphone-innercutout.flag
DIAG_FLAG=/var/mobile/Library/Caches/vphone-touchdiag.flag
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $O/results.txt }
front() { rpc apps.foreground | jq -r '.result.bundle_id // "none"' }
shot() { send "{\"t\":\"screenshot\",\"path\":\"$O/$1.png\"}" > /dev/null }
home() { rpc input.button '{"name":"home"}' > /dev/null; sleep 2 }
stopvm() {
  rpc system.shutdown > /dev/null; sleep 8
  kill -INT $(cat $R/window-$1/pid) 2>/dev/null; sleep 3
  pkill -INT -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 4
  pkill -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 1
}
: > $O/results.txt
# A small saved window turns host taps near an edge into edge touches.
defaults delete com.vphone.bundle "NSWindow Frame vphone-scene-/Users/kolar/.vphone/machines/duo-m5-dd" 2> /dev/null

zsh $R/window-launch.sh 0 regress-$STATE-prep > /dev/null 2>&1; sleep 20
rpc files.write "{\"path\":\"$DIAG_FLAG\",\"content\":\"\"}" > /dev/null
if [[ $STATE == on ]]; then
  rpc files.write "{\"path\":\"$FIX_FLAG\",\"content\":\"$CUTOUT\"}" > /dev/null
else
  rpc files.remove "{\"path\":\"$FIX_FLAG\"}" > /dev/null
fi
ideviceinstaller -u $U install /Users/kolar/vphone-duo-m5/src/geo-probe/build/device/GeoBare.ipa > /dev/null 2>&1
note "state $STATE; libraries: $(rpc environment.status | jq -c '[.result.libraries[] | select(.name | test("innercutout")) | .sha256[0:12]]')"
stopvm regress-$STATE-prep

zsh $R/window-launch.sh 0 regress-$STATE > /dev/null 2>&1
rpc screen.unlock '{"timeout":30}' > /dev/null; home; home
dir=$(rpc apps.data_dir "{\"bundle_id\":\"$BID\"}" | jq -r '.result.data_path // empty')

# Starts GeoBare with empty logs.
geo_start() {
  rpc apps.terminate "{\"bundle_id\":\"$BID\"}" > /dev/null
  for f in app-events.log events.log touches.log; do rpc files.remove "{\"path\":\"$dir/Documents/$f\"}" > /dev/null; done
  rpc apps.launch "{\"bundle_id\":\"$BID\"}" > /dev/null; sleep 5
}
# Phase counts from GeoBare's window log: "began moved ended cancelled".
geo_phases() {
  send "{\"t\":\"pull\",\"path\":\"$dir/Documents/events.log\",\"local\":\"$O/$1-events.log\"}" > /dev/null
  [[ -f $O/$1-events.log ]] || { print "no events"; return }
  jq -s -r '[.[] | select(.type == 0) | .touches[]?.phase] as $p
    | "began \([$p[] | select(. == 0)] | length) moved \([$p[] | select(. == 1)] | length) ended \([$p[] | select(. == 3)] | length) cancelled \([$p[] | select(. == 4)] | length)"' $O/$1-events.log
}
taps() {
  for p in "200 300" "450 300" "200 650" "450 650"; do
    set -- ${=p}; rpc input.tap "{\"x\":$1,\"y\":$2}" > /dev/null; sleep 1.2
  done
}

# 1. Landscape: rotate, then four vphoned taps in GeoBare's upright points.
geo_start
rpc display.rotation '{"orientation":"landscape-left"}' > /dev/null; sleep 4
note "landscape: orientation $(rpc display.orientation | jq -c .result)"
shot landscape-geobare
for p in "200 200" "700 200" "200 500" "700 500"; do
  set -- ${=p}; rpc input.tap "{\"x\":$1,\"y\":$2}" > /dev/null; sleep 1.2
done
note "landscape GeoBare (4 taps): $(geo_phases landscape)"
home; shot landscape-home
rpc display.rotation '{"orientation":"portrait"}' > /dev/null; sleep 4
note "portrait again: $(rpc display.orientation | jq -c .result)"

# 2. Drag: one swipe in GeoBare.
geo_start
rpc input.swipe '{"x1":200,"y1":300,"x2":450,"y2":650,"seconds":0.5,"steps":20}' > /dev/null; sleep 1.5
note "drag GeoBare (1 swipe): $(geo_phases drag)"
home
rpc input.swipe '{"x1":550,"y1":500,"x2":100,"y2":500,"seconds":0.3,"steps":15}' > /dev/null; sleep 2
shot drag-home-page2
home

# 3. Cancel: finger down in GeoBare, Home pressed while it is down, finger up.
geo_start
rpc input.touch '{"phase":"down","x":330,"y":480}' > /dev/null; sleep 0.5
rpc input.touch '{"phase":"move","x":340,"y":500}' > /dev/null; sleep 0.3
home
rpc input.touch '{"phase":"up","x":340,"y":500}' > /dev/null; sleep 1
note "cancel: foreground after Home $(front)"
geo_start; taps
note "after cancel, GeoBare (4 taps): $(geo_phases after-cancel)"

# 4. Background/foreground: Home, relaunch without terminating, taps.
home
rpc apps.launch "{\"bundle_id\":\"$BID\"}" > /dev/null; sleep 3
for f in app-events.log events.log touches.log; do rpc files.remove "{\"path\":\"$dir/Documents/$f\"}" > /dev/null; done
taps
note "resumed GeoBare (4 taps): $(geo_phases resumed)"

# 5. Lock/unlock.
rpc input.button '{"name":"power"}' > /dev/null; sleep 4
rpc screen.unlock '{"timeout":30}' > /dev/null; sleep 3
note "unlock: foreground $(front)"
geo_start; taps
note "after unlock, GeoBare (4 taps): $(geo_phases unlocked)"

# 6. Safari: open, tap the address field, screenshots.
home
rpc apps.launch '{"bundle_id":"com.apple.mobilesafari"}' > /dev/null; sleep 5
shot safari
rpc input.tap '{"x":334,"y":905}' > /dev/null; sleep 2
shot safari-address-tap
note "safari: foreground $(front)"
home

stopvm regress-$STATE
note "stopped"

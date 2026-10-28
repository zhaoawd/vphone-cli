#!/bin/zsh
# The two open E1 observations, correction on: Safari driven by touch (Dock tap,
# address field, typed URL, page tap) in portrait, a landscape screenshot of it,
# and the phases GeoBare receives for a touch interrupted by Home. Expects the
# VM stopped; sets the correction flag, cold boots, ends stopped.
#   e1-gaps.sh
set -uo pipefail
R=/Users/kolar/vphone-duo-m5/run/phase2
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
O=$R/e1-gaps
BID=com.autophone.geobare
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $O/results.txt }
front() { rpc apps.foreground | jq -r '.result.bundle_id // "none"' }
shot() { send "{\"t\":\"screenshot\",\"path\":\"$O/$1.png\"}" > /dev/null }
home() { rpc input.button '{"name":"home"}' > /dev/null; sleep 2 }
: > $O/results.txt
defaults delete com.vphone.bundle "NSWindow Frame vphone-scene-/Users/kolar/.vphone/machines/duo-m5-dd" 2> /dev/null

# Boot 1 sets the correction flag; boot 2 is the measured cold boot.
zsh $R/window-launch.sh 0 gaps-prep > /dev/null 2>&1; sleep 20
rpc files.write '{"path":"/var/mobile/Library/Caches/vphone-innercutout.flag","content":"399 30 37 37"}' > /dev/null
rpc system.shutdown > /dev/null; sleep 8
kill -INT $(cat $R/window-gaps-prep/pid) 2>/dev/null; sleep 3
pkill -INT -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 4
pkill -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 1
zsh $R/window-launch.sh 0 gaps > /dev/null 2>&1
rpc screen.unlock '{"timeout":30}' > /dev/null; home; home
note "fix flag: $(rpc files.read '{"path":"/var/mobile/Library/Caches/vphone-innercutout.flag"}' | jq -c '.result.content // .error')"

# Safari by touch: Dock icon (vphoned tap), address field, URL, return.
rpc apps.terminate '{"bundle_id":"com.apple.mobilesafari"}' > /dev/null
rpc input.tap '{"x":315,"y":900}' > /dev/null; sleep 5
note "dock tap: foreground $(front) (want com.apple.mobilesafari)"
shot safari-1-open
rpc input.tap '{"x":224,"y":48}' > /dev/null; sleep 2
shot safari-2-address-focus
rpc input.type '{"text":"neverssl.com\n"}' > /dev/null; sleep 6
shot safari-3-navigated
rpc input.tap '{"x":334,"y":500}' > /dev/null; sleep 2
shot safari-4-page-tap
note "safari after page tap: foreground $(front)"
rpc display.rotation '{"orientation":"landscape-left"}' > /dev/null; sleep 4
shot safari-5-landscape
rpc input.tap '{"x":460,"y":49}' > /dev/null; sleep 2
shot safari-6-landscape-focus
rpc input.type '{"text":"example.com\n"}' > /dev/null; sleep 6
shot safari-7-landscape-navigated
rpc display.rotation '{"orientation":"portrait"}' > /dev/null; sleep 3
home

# Cancellation: began, Home while down, release, then the log before any reset.
dir=$(rpc apps.data_dir "{\"bundle_id\":\"$BID\"}" | jq -r '.result.data_path // empty')
rpc apps.terminate "{\"bundle_id\":\"$BID\"}" > /dev/null
for f in app-events.log events.log touches.log; do rpc files.remove "{\"path\":\"$dir/Documents/$f\"}" > /dev/null; done
rpc apps.launch "{\"bundle_id\":\"$BID\"}" > /dev/null; sleep 5
rpc input.touch '{"phase":"down","x":0.49,"y":0.5}' > /dev/null; sleep 0.5
rpc input.touch '{"phase":"move","x":0.51,"y":0.53}' > /dev/null; sleep 0.3
rpc input.button '{"name":"home"}' > /dev/null; sleep 1.5
rpc input.touch '{"phase":"up","x":0.51,"y":0.53}' > /dev/null; sleep 1
send "{\"t\":\"pull\",\"path\":\"$dir/Documents/events.log\",\"local\":\"$O/cancel-events.log\"}" > /dev/null
send "{\"t\":\"pull\",\"path\":\"$dir/Documents/app-events.log\",\"local\":\"$O/cancel-app-events.log\"}" > /dev/null
note "cancel sequence (window log, time phase x,y): $(jq -s -r '[.[] | select(.type == 0) | "\(.time | . * 1000 | floor / 1000) \(.touches[0].phase) \(.touches[0].x | floor),\(.touches[0].y | floor)"] | join("; ")' $O/cancel-events.log 2>/dev/null)"
note "foreground after Home: $(front)"
rpc apps.launch "{\"bundle_id\":\"$BID\"}" > /dev/null; sleep 3
for f in events.log; do rpc files.remove "{\"path\":\"$dir/Documents/$f\"}" > /dev/null; done
for p in "200 300" "450 650"; do set -- ${=p}; rpc input.tap "{\"x\":$1,\"y\":$2}" > /dev/null; sleep 1.2; done
send "{\"t\":\"pull\",\"path\":\"$dir/Documents/events.log\",\"local\":\"$O/after-cancel-events.log\"}" > /dev/null
note "after: $(jq -s -r '[.[] | select(.type == 0) | "\(.touches[0].phase) \(.touches[0].x | floor),\(.touches[0].y | floor)"] | join("; ")' $O/after-cancel-events.log 2>/dev/null)"

rpc system.shutdown > /dev/null; sleep 8
kill -INT $(cat $R/window-gaps/pid) 2>/dev/null; sleep 3
pkill -INT -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 4
pkill -f 'machines/duo-m5-dd/' 2>/dev/null
note "stopped"

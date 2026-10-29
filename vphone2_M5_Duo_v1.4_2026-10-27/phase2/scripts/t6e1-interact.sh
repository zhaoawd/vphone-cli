#!/bin/zsh
# T6 at E1 on duo-m5-dd, frozen candidate: one interaction round in a windowed
# launch with the saved window frame kept. GeoBare taps (vphoned) in portrait,
# landscape-left and landscape-right; Home icons by host view and vphoned;
# Safari by touch (Dock, address field, typed URL); food_ordering; background
# and foreground with pid checks; respring, lock/unlock and a guest restart,
# each followed by GeoBare taps. Expects the VM stopped; ends stopped.
set -uo pipefail
VM=duo-m5-dd
R=/Users/kolar/vphone-duo-m5/run/phase2
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=/Users/kolar/vphone-duo-m5/run/t6-e1/interact
BID=com.autophone.geobare
mkdir -p $OUT; : > $OUT/results.txt
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null || true }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
fg() { rpc apps.foreground | jq -r '.result.bundle_id // "?"' }
pidof() { rpc processes.list | jq -r --arg n "$1" '[.result.processes[] | select(.name==$n) | .pid][0] // "none"' }
shot() { send "{\"t\":\"screenshot\",\"path\":\"$OUT/$1.png\"}" > /dev/null }
step() { print -r -- "$(date +%T) $1" | tee -a $OUT/results.txt }
home() { rpc input.button '{"name":"home"}' > /dev/null; sleep 3 }
ready() {
  local t0=$(date +%s)
  while (( $(date +%s) - t0 < 300 )); do
    [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
dir=""
geo() {  # geo <label> <x y>...: fresh GeoBare logs, vphoned taps, phase counts
  local label=$1; shift
  [[ -z $dir ]] && dir=$(rpc apps.data_dir "{\"bundle_id\":\"$BID\"}" | jq -r '.result.data_path // empty')
  rpc apps.terminate "{\"bundle_id\":\"$BID\"}" > /dev/null
  rpc files.remove "{\"path\":\"$dir/Documents/events.log\"}" > /dev/null
  rpc apps.launch "{\"bundle_id\":\"$BID\"}" > /dev/null; sleep 5
  local n=0
  while (( $# >= 2 )); do
    rpc input.tap "{\"x\":$1,\"y\":$2}" > /dev/null; sleep 1.2; shift 2; n=$(( n + 1 ))
  done
  rm -f $OUT/$label-events.log
  send "{\"t\":\"pull\",\"path\":\"$dir/Documents/events.log\",\"local\":\"$OUT/$label-events.log\"}" > /dev/null
  local counts="no events"
  [[ -f $OUT/$label-events.log ]] && counts=$(jq -s -r '[.[] | select(.type == 0) | .touches[]?.phase] as $p | "began \([$p[] | select(. == 0)] | length) ended \([$p[] | select(. == 3)] | length)"' $OUT/$label-events.log)
  step "$label GeoBare ($n taps): $counts"
}
P4=(200 300 450 300 200 650 450 650)
L4=(200 200 700 200 200 500 700 500)

step "window frame kept: $(defaults read com.vphone.bundle "NSWindow Frame vphone-scene-/Users/kolar/.vphone/machines/$VM" 2>/dev/null)"
zsh $R/window-launch.sh 0 t6e1-interact > /dev/null 2>&1
lp=$(cat $R/window-t6e1-interact/pid)
t0=$(date +%s)
step "unlock: $(rpc screen.unlock '{"timeout":30}' | jq -c '.result | {locked, screen_off}')"
home; home

geo portrait $P4
rpc display.rotation '{"orientation":"landscape-left"}' > /dev/null; sleep 4
step "landscape-left: $(rpc display.orientation | jq -c .result)"
geo landscape-left $L4
rpc display.rotation '{"orientation":"landscape-right"}' > /dev/null; sleep 4
step "landscape-right: $(rpc display.orientation | jq -c .result)"
shot landscape-right
geo landscape-right $L4
rpc display.rotation '{"orientation":"portrait"}' > /dev/null; sleep 4
step "portrait: $(rpc display.orientation | jq -c .result)"
home; home

# Home icons, host view (pixels) and vphoned (points).
for entry in 281.5,465.5=com.apple.mobilenotes 493,465.5=com.apple.Maps; do
  p=${entry%%=*}; want=${entry#*=}; ix=${p%,*}; iy=${p#*,}
  for src in host guest; do
    home; home
    if [[ $src == host ]]; then
      x=$(( ix * 3 )); y=$(( iy * 3 ))
      send "{\"t\":\"tap\",\"x\":${x%.*},\"y\":${y%.*},\"screen\":false}" > /dev/null
    else
      rpc input.tap "{\"x\":${ix%.*},\"y\":${iy%.*}}" > /dev/null
    fi
    sleep 5
    step "icon $src $want: foreground=$(fg)"
  done
done
home

# Safari by touch.
rpc apps.terminate '{"bundle_id":"com.apple.mobilesafari"}' > /dev/null
rpc input.tap '{"x":315,"y":900}' > /dev/null; sleep 5
step "safari dock tap: foreground=$(fg)"
rpc input.tap '{"x":224,"y":48}' > /dev/null; sleep 2
rpc input.type '{"text":"example.org\n"}' > /dev/null; sleep 8; shot safari-typed
step "safari address + example.org: foreground=$(fg)"
safari_pid=$(pidof MobileSafari)

food=$(rpc apps.list | jq -r '[.result | (.apps // .) | .[]? | .bundle_id | select(test("food|ordering|autophone.food"; "i"))][0] // empty')
if [[ -n $food ]]; then
  rpc apps.launch "{\"bundle_id\":\"$food\"}" > /dev/null; sleep 8
  rpc input.tap '{"x":334,"y":480}' > /dev/null; sleep 3; shot food
  step "food_ordering ($food): foreground=$(fg)"
else
  step "food_ordering: not installed"
fi
home
rpc apps.launch '{"bundle_id":"com.apple.mobilesafari"}' > /dev/null; sleep 5
step "safari back: foreground=$(fg) pid=$(pidof MobileSafari) (was $safari_pid)"
home

sb=$(pidof SpringBoard)
step "respring: $(rpc system.respring '{"force":true}' | jq -c '{ok, error}')"
sleep 20; rpc screen.unlock '{"timeout":30}' > /dev/null; home
step "SpringBoard pid $sb -> $(pidof SpringBoard)"
geo after-respring $P4

rpc input.button '{"name":"power"}' > /dev/null; sleep 4
step "locked: $(rpc device.screen | jq -c '.result | {locked, screen_off}')"
rpc screen.unlock '{"timeout":30}' > /dev/null; sleep 3
geo after-unlock $P4

step "guest restart: $(rpc system.reboot '{"force":true}' | jq -c '{ok, error}')"
sleep 20
ready && step "vphoned back after restart" || step "vphoned not back after restart"
sleep 40
rpc screen.unlock '{"timeout":30}' > /dev/null; home; home
dir=""
geo after-guest-restart $P4

step "processes: SB=$(pidof SpringBoard) BB=$(pidof backboardd) vphoned=$(pidof vphoned)"
step "crashes since start: $(rpc logs.crashes | jq -r --argjson t $t0 '[.result.crashes[]? | select(.mtime >= $t) | .process] | group_by(.) | map("\(.[0])=\(length)") | join(" ")')"
rpc system.shutdown > /dev/null; sleep 8
kill -INT $lp 2>/dev/null; sleep 3
pkill -INT -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 4
pkill -f 'machines/duo-m5-dd/' 2>/dev/null
step "stopped; window frame now: $(defaults read com.vphone.bundle "NSWindow Frame vphone-scene-/Users/kolar/.vphone/machines/$VM" 2>/dev/null)"

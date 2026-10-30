#!/bin/zsh
# food_ordering showcase on duo-m5-fold214 across Duo postures (cover, unfolded,
# partially open, open-flat landscape, folded), recorded with the VM window's
# own recorder (Shift-Command-R). Taps resolve elements by accessibility label.
#   food-record.sh <tag>
set -uo pipefail
TAG=${1:?tag}
T=/Users/kolar/vphone-duo-m5/run/fold214/tools
OUT=/Users/kolar/vphone-duo-m5/run/fold214/demo/$TAG
APP=com.autophone.foodorderingdemo.v2
mkdir -p $OUT
pid=$(pgrep -f 'vphone-vm.*duo-m5-fold214' | head -1)
[[ -n $pid ]] || { print "VM window not running"; exit 1 }
menu_title() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get name of menu item 1 of menu 1 of menu bar item \"截取\" of menu bar 1" 2>/dev/null }
toggle_recording() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" \
            -e 'delay 0.5' -e 'tell application "System Events" to keystroke "r" using {command down, shift down}'
}
log() { print -r -- "$(date +%T) $*" | tee -a $OUT/actions.log }
act() { log "$1 $($T/rpc.sh $2 "${3:-{\}}" | jq -c '{ok, error}')"; /bin/sleep ${4:-3} }
tap_label() { # tap_label <label or field placeholder> [settle]
  local f=$($T/rpc.sh ui.describe | jq -c --arg l "$1" '[.result.elements.elements[]? | select(.label == $l or .value == $l) | .frame][0] // empty')
  [[ -n $f ]] || { log "tap $1: not found"; return }
  local x=$(jq -n "$f | .x + .width/2") y=$(jq -n "$f | .y + .height/2")
  # input.tap takes cover points (466x678) and stretches them over the inner
  # panel (669x951 pt) while unfolded; ui.describe frames are inner points.
  if [[ $($T/rpc.sh display.pose | jq -r '.result.hinge') != 1 ]]; then
    x=$(jq -n "$x * 466 / 669"); y=$(jq -n "$y * 678 / 951")
  fi
  act "tap $1 ($x,$y)" input.tap "{\"x\":$x,\"y\":$y}" ${2:-2}
}

$T/rpc.sh screen.unlock '{"timeout":30}' > /dev/null
$T/rpc.sh display.posture '{"hinge":"closed"}' > /dev/null
$T/rpc.sh display.rotation '{"orientation":"portrait"}' > /dev/null
$T/rpc.sh apps.terminate "{\"bundle_id\":\"$APP\"}" > /dev/null 2>&1
$T/rpc.sh input.button '{"name":"home"}' > /dev/null
/bin/sleep 3
[[ $(menu_title) == "开始录制" ]] || { print "recorder not idle: $(menu_title)"; exit 1 }
before=$(/bin/ls -t ~/Desktop | grep -E '^vphone-recording' | head -1)
: > $OUT/actions.log
toggle_recording; /bin/sleep 2

# 1. Cover (folded): launch, sign-in form, type an email.
act "launch on cover"      apps.launch "{\"bundle_id\":\"$APP\"}" 4
tap_label "Enter your email"
act "type email"           input.type '{"text":"demo@vphone.dev","delay_ms":60}' 2
# 2. Unfold with the keyboard up: the form continues on the inner display.
act "unfold"               display.posture '{"hinge":"open"}' 4
tap_label "Enter your password"
act "type password"        input.type '{"text":"duo-demo","delay_ms":60}' 2
act "dismiss keyboard"     input.key '{"name":"return"}' 2
# 3. Half open, then flat and landscape.
act "partially open"       display.posture '{"hinge":"partially-open"}' 3
act "open flat"            display.posture '{"hinge":"open-flat"}' 3
act "landscape"            display.rotation '{"orientation":"landscape-left"}' 4
act "portrait"             display.rotation '{"orientation":"portrait"}' 4
# 4. Navigate to Sign Up on the inner display.
tap_label "Sign Up" 3
tap_label "Enter your full name"
act "type name"            input.type '{"text":"Duo Demo","delay_ms":60}' 2
act "dismiss keyboard"     input.key '{"name":"return"}' 2
# 5. Fold back: the app returns to the cover with the same screen.
act "fold"                 display.posture '{"hinge":"closed"}' 4
act "unfold again"         display.posture '{"hinge":"open"}' 4
act "fold again"           display.posture '{"hinge":"closed"}' 3

toggle_recording; /bin/sleep 3
rec=$(/bin/ls -t ~/Desktop | grep -E '^vphone-recording' | head -1)
[[ -n $rec && $rec != $before ]] || { print "no new recording"; exit 1 }
mv ~/Desktop/$rec $OUT/recording.mov
print -r -- "saved $OUT/recording.mov"

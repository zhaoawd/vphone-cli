#!/bin/zsh
# Short iPhone Duo demo video of duo-m5-fold214, recorded with the VM window's
# own recorder (Shift-Command-R) while a simple fold/app sequence runs.
#   demo-record.sh <tag>
set -uo pipefail
TAG=${1:?tag}
T=/Users/kolar/vphone-duo-m5/run/fold214/tools
OUT=/Users/kolar/vphone-duo-m5/run/fold214/demo/$TAG
mkdir -p $OUT
pid=$(pgrep -f 'vphone-vm.*duo-m5-fold214' | head -1)
[[ -n $pid ]] || { print "VM window not running"; exit 1 }
menu_title() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get name of menu item 1 of menu 1 of menu bar item \"截取\" of menu bar 1" 2>/dev/null }
toggle_recording() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" \
            -e 'delay 0.5' -e 'tell application "System Events" to keystroke "r" using {command down, shift down}'
}
act() { print -r -- "$1"; $T/rpc.sh $2 "${3:-{\}}" | jq -c '{ok, error}'; /bin/sleep ${4:-3} }

$T/rpc.sh screen.unlock '{"timeout":30}' > /dev/null
$T/rpc.sh display.posture '{"hinge":"closed"}' > /dev/null
$T/rpc.sh input.button '{"name":"home"}' > /dev/null
/bin/sleep 3
[[ $(menu_title) == "开始录制" ]] || { print "recorder not idle: $(menu_title)"; exit 1 }
before=$(/bin/ls -t ~/Desktop | grep -E '^vphone-recording' | head -1)
toggle_recording; /bin/sleep 2

act "cover home"            display.posture '{"hinge":"closed"}' 2
act "Safari on cover"       apps.launch '{"bundle_id":"com.apple.mobilesafari"}' 4
act "unfold (Safari)"       display.posture '{"hinge":"open"}' 4
act "fold (Safari)"         display.posture '{"hinge":"closed"}' 4
act "unfold again"          display.posture '{"hinge":"open"}' 3
act "inner home"            input.button '{"name":"home"}' 3
act "Settings on inner"     apps.launch '{"bundle_id":"com.apple.Preferences"}' 4
act "inner home"            input.button '{"name":"home"}' 3
act "Photos on inner"       apps.launch '{"bundle_id":"com.apple.mobileslideshow"}' 4
act "fold (Photos)"         display.posture '{"hinge":"closed"}' 4
act "cover home"            input.button '{"name":"home"}' 3

toggle_recording; /bin/sleep 3
rec=$(/bin/ls -t ~/Desktop | grep -E '^vphone-recording' | head -1)
[[ -n $rec && $rec != $before ]] || { print "no new recording"; exit 1 }
mv ~/Desktop/$rec $OUT/recording.mov
print -r -- "saved $OUT/recording.mov"

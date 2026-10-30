#!/bin/zsh
# F5: record duo-m5-fold214's display with the VM window's own recorder
# (Capture > Start Recording, Shift-Command-R) while a fixed fold sequence
# runs through vphoned. Every action is logged with its offset from the
# recording start, for matching against black frames afterwards.
#   f5-record.sh <tag>
set -uo pipefail
TAG=${1:?tag}
T=/Users/kolar/vphone-duo-m5/run/fold214/tools
OUT=/Users/kolar/vphone-duo-m5/run/fold214/f5/$TAG
mkdir -p $OUT
ACT=$OUT/actions.tsv
pid=$(pgrep -f 'vphone-vm.*duo-m5-fold214' | head -1)
[[ -n $pid ]] || { print "VM window not running"; exit 1 }

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }
menu_title() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get name of menu item 1 of menu 1 of menu bar item \"截取\" of menu bar 1" 2>/dev/null }
toggle_recording() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" \
            -e 'delay 0.5' -e 'tell application "System Events" to keystroke "r" using {command down, shift down}'
}
act() { # act <label> <method> [params] [settle-seconds]
  local t=$(now)
  local r=$($T/rpc.sh $2 "${3:-{\}}" | jq -c '{ok, error}')
  printf "%.3f\t%s\t%s\t%.3f\n" $(( t - T0 )) "$1" "$r" $t | tee -a $ACT
  /bin/sleep ${4:-4}
}

# Screen on, unlocked, closed, on the cover's Home screen before recording.
$T/rpc.sh screen.unlock '{"timeout":30}' | jq -c .result
$T/rpc.sh display.posture '{"hinge":"closed"}' > /dev/null
$T/rpc.sh input.button '{"name":"home"}' > /dev/null
/bin/sleep 3
[[ $(menu_title) == "开始录制" ]] || { print "recorder not idle: $(menu_title)"; exit 1 }

before=$(/bin/ls -t ~/Desktop | grep -E '^vphone-recording' | head -1)
T0=$(now); toggle_recording; /bin/sleep 1
print -r -- $T0 > $OUT/t0.txt
print -r -- "recording: $(menu_title)"
: > $ACT

act baseline-closed display.posture '{"hinge":"closed"}' 3
for i in 1 2 3 4 5 6; do
  act "home-open-$i" display.posture '{"hinge":"open"}'
  act "home-close-$i" display.posture '{"hinge":"closed"}'
done
act safari-launch-cover apps.launch '{"bundle_id":"com.apple.mobilesafari"}' 5
act safari-open display.posture '{"hinge":"open"}'
act safari-close display.posture '{"hinge":"closed"}'
act safari-open-2 display.posture '{"hinge":"open"}'
act home-inner input.button '{"name":"home"}'
act settings-launch-inner apps.launch '{"bundle_id":"com.apple.Preferences"}' 5
act home-inner-2 input.button '{"name":"home"}'
act photos-launch-inner apps.launch '{"bundle_id":"com.apple.mobileslideshow"}' 5
act photos-close display.posture '{"hinge":"closed"}'
act home-cover input.button '{"name":"home"}'
act rotate-cover-left display.rotation '{"orientation":"landscape-left"}'
act rotate-cover-portrait display.rotation '{"orientation":"portrait"}'
act rotate-open display.posture '{"hinge":"open"}'
act rotate-inner-portrait display.rotation '{"orientation":"portrait"}'
act rotate-inner-landscape display.rotation '{"orientation":"landscape-left"}'
for i in 1 2 3 4; do
  act "rapid-close-$i" display.posture '{"hinge":"closed"}' 1
  act "rapid-open-$i" display.posture '{"hinge":"open"}' 1
done
act final-close display.posture '{"hinge":"closed"}' 4

toggle_recording; /bin/sleep 3
print -r -- "recorder: $(menu_title)"
rec=$(/bin/ls -t ~/Desktop | grep -E '^vphone-recording' | head -1)
[[ -n $rec && $rec != $before ]] || { print "no new recording"; exit 1 }
mv ~/Desktop/$rec $OUT/recording.mov
print -r -- "saved $OUT/recording.mov"

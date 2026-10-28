#!/bin/zsh
# Home screen check for one state of the cutout experiment, per tap. Expects the
# VM stopped; ends stopped.
#   cutout-home.sh C0|C1|C2 [inner|outer]
#   outer: boots at the outer size, taps the outer grid and adds GeoBare.
set -uo pipefail
RUN=${1:?C0|C1|C2}
SIZE=${2:-inner}
# Boot 1 syncs libraries and sets the flags; boot 2 is a cold boot. The icon
# centres are fixed, measured from screenshots. For four icons, by host view
# and by vphoned: press
# Home, require SpringBoard frontmost, screenshot, tap the icon centre, wait,
# screenshot, read the foreground app and compare it with the icon's bundle
# ID. The diagnostic log then gives the window and view each tap hit.
CUTOUT="399 30 37 37"
R=/Users/kolar/vphone-duo-m5/run/phase2
S=/Users/kolar/.vphone/machines/duo-m5-dd/vphone.sock
O=$R/cutout-home/$RUN
[[ $SIZE == outer ]] && O=$R/cutout-home/outer-$RUN
LAUNCH=window-launch.sh; [[ $SIZE == outer ]] && LAUNCH=window-launch-any.sh
FIX_FLAG=/var/mobile/Library/Caches/vphone-innercutout.flag
FIX_LOG=/var/mobile/Library/Caches/vphone-innercutout.log
DIAG_FLAG=/var/mobile/Library/Caches/vphone-touchdiag.flag
DIAG_LOG=/var/mobile/Library/Caches/vphone-touchdiag.log
mkdir -p $O
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $O/results.txt }
front() { rpc apps.foreground | jq -r '.result.bundle_id // "none"' }
stopvm() {
  rpc system.shutdown > /dev/null; sleep 8
  kill -INT $(cat $R/window-$1/pid) 2>/dev/null; sleep 3
  pkill -INT -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 4
  pkill -f 'machines/duo-m5-dd/' 2>/dev/null; sleep 1
}
: > $O/results.txt

zsh $R/$LAUNCH 0 home-$RUN-prep > /dev/null 2>&1; sleep 20
for f in $FIX_LOG $DIAG_LOG; do rpc files.remove "{\"path\":\"$f\"}" > /dev/null; done
rpc files.write "{\"path\":\"$DIAG_FLAG\",\"content\":\"\"}" > /dev/null
if [[ $RUN == C1 ]]; then
  rpc files.write "{\"path\":\"$FIX_FLAG\",\"content\":\"$CUTOUT\"}" > /dev/null
else
  rpc files.remove "{\"path\":\"$FIX_FLAG\"}" > /dev/null
fi
note "run $RUN: fix flag $([[ $RUN == C1 ]] && print "\"$CUTOUT\"" || print absent)"
note "libraries: $(rpc environment.status | jq -c '[.result.libraries[] | select(.name | test("touchdiag|innercutout")) | {name, sha: (.sha256 // "absent" | .[0:12])}]')"
stopvm home-$RUN-prep

zsh $R/$LAUNCH 0 home-$RUN > /dev/null 2>&1
rpc screen.unlock '{"timeout":30}' > /dev/null
rpc input.button '{"name":"home"}' > /dev/null
sleep 40
send "{\"t\":\"pull\",\"path\":\"$DIAG_LOG\",\"local\":\"$O/touchdiag-icons.log\"}" > /dev/null
note "live provider: $(grep -A1 '^statusbar-window SBStatusBarWindow' $O/touchdiag-icons.log | grep -oE 'provider=[^ ]+' | head -1)"
# Icon centres measured from the C0/C1 screenshots (page 1, identical in both):
# the diagnostic's timed dump returned other views, so it is not used here.
picked=(281.5,465.5=com.apple.mobilenotes 493,465.5=com.apple.Maps 175.5,583.5=com.apple.tv 387.5,701.8=com.apple.Preferences)
# The outer size's grid, measured the same way.
[[ $SIZE == outer ]] && picked=(145,380=com.apple.mobilenotes 321,380=com.apple.Maps 57,479=com.apple.tv 233,578=com.apple.Preferences)
note "icons: ${picked[*]}"

n=0
for src in host guest; do for entry in $picked; do
  n=$(( n + 1 ))
  p=${entry%%=*}; want=${entry#*=}; ix=${p%,*}; iy=${p#*,}
  rpc input.button '{"name":"home"}' > /dev/null; sleep 3
  rpc input.button '{"name":"home"}' > /dev/null; sleep 3
  before=$(front)
  send "{\"t\":\"screenshot\",\"path\":\"$O/tap$n-before.png\"}" > /dev/null
  if [[ $src == host ]]; then
    x=$(( ix * 3 )); y=$(( iy * 3 ))
    send "{\"t\":\"tap\",\"x\":${x%.*},\"y\":${y%.*},\"screen\":false}" > /dev/null
  else
    rpc input.tap "{\"x\":${ix%.*},\"y\":${iy%.*}}" > /dev/null
  fi
  sleep 5
  after=$(front)
  send "{\"t\":\"screenshot\",\"path\":\"$O/tap$n-after.png\"}" > /dev/null
  verdict=$([[ $after == $want ]] && print opened || print "not opened")
  note "tap$n $src $p want=$want before=$before after=$after: $verdict"
done; done
rpc input.button '{"name":"home"}' > /dev/null; sleep 2
if [[ $SIZE == outer ]]; then
  zsh $R/touch-trace.sh home-outer-$RUN 1398 2034 > /dev/null 2>&1
  note "geobare: $(sed -n 2p $R/touch-trace/home-outer-$RUN/results.txt)"
fi

send "{\"t\":\"pull\",\"path\":\"$DIAG_LOG\",\"local\":\"$O/touchdiag.log\"}" > /dev/null
send "{\"t\":\"pull\",\"path\":\"$FIX_LOG\",\"local\":\"$O/innercutout.log\"}" > /dev/null
note "fix log: $(grep -v '^$' $O/innercutout.log 2>/dev/null | tail -1)"
note "hits: $(grep -E '^t=' $O/touchdiag.log 2>/dev/null | grep 'phase=0' | grep -v _UISystemGestureWindow | grep -oE 'window=[A-Za-z_]+|view=[A-Za-z_]+' | paste - - | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
stopvm home-$RUN
note "stopped"

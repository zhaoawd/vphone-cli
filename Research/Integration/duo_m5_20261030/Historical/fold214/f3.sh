#!/bin/zsh
# F3: touch mapping on the cover and the inner display in each orientation,
# through both input paths, against the touch probe page in Safari
# (f3/touch-server.mjs on 192.168.64.1:18766).
#   f3.sh <tag>
# For each posture x orientation it taps five points of the UI (in points)
# through vphoned input.tap (CoreDevice touchscreen) and the window's host
# tap (VZ touchscreen, screenshot pixels), and prints what the page received:
# the offset (client - injected) must be the same for all ten taps.
set -uo pipefail
TAG=${1:?tag}
T=/Users/kolar/vphone-duo-m5/run/fold214/tools
S=/Users/kolar/.vphone/machines/duo-m5-fold214/vphone.sock
D=/Users/kolar/vphone-duo-m5/run/fold214/f3
O=$D/$TAG; mkdir -p $O
TL=$D/touches.log
rpc() { $T/rpc.sh "$@" }
host() { print -r -- "$1" | nc -U -w 10 $S > /dev/null }
last() { tail -1 $TL | jq -r '"\(.x) \(.y) \(.w) \(.h) \(.o)"' }
shot() {
  local p=$(print -r -- '{"t":"screenshot"}' | nc -U -w 15 $S | jq -r '.path // empty')
  [[ -n $p && -f $p ]] && mv "$p" $O/$1.jpg && sips -Z 400 $O/$1.jpg --out $O/s-$1.jpg > /dev/null
}

rpc screen.unlock '{"timeout":30}' > /dev/null
for posture in closed open-flat; do
  for orient in portrait landscape-left landscape-right upside-down; do
    rpc display.posture "{\"hinge\":\"$posture\"}" > /dev/null; /bin/sleep 2
    rpc apps.open_url '{"url":"http://192.168.64.1:18766/"}' > /dev/null; /bin/sleep 3
    rpc display.rotation "{\"orientation\":\"$orient\"}" > /dev/null; /bin/sleep 3
    read w h <<< $(rpc device.screen | jq -r '.result | "\(.width) \(.height)"')
    read pw ph <<< $(print -r -- '{"t":"display.geometry"}' | nc -U -w 10 $S | jq -r '.result.screenshot_pixels | "\(.[0]) \(.[1])"')
    shot $posture-$orient
    print -r -- "== $posture $orient: ui ${w}x${h} pt, screenshot ${pw}x${ph} px" | tee -a $O/result.txt
    for f in "0.5 0.5" "0.3 0.4" "0.7 0.4" "0.3 0.75" "0.7 0.75"; do
      read fx fy <<< $f
      x=$(( w * fx )); y=$(( h * fy )); x=${x%.*}; y=${y%.*}
      for via in vphoned host; do
        n=$(wc -l < $TL)
        if [[ $via == vphoned ]]; then rpc input.tap "{\"x\":$x,\"y\":$y}" > /dev/null
        else host "{\"t\":\"tap\",\"x\":$(( x * pw / w )),\"y\":$(( y * ph / h ))}"; fi
        /bin/sleep 0.8
        if (( $(wc -l < $TL) > n )); then
          read cx cy vw vh o <<< $(last)
          printf "  %-7s tap (%4d,%4d) -> client (%7.1f,%7.1f) offset (%6.1f,%6.1f) viewport %sx%s %s\n" \
            $via $x $y $cx $cy $(( cx - x )) $(( cy - y )) $vw $vh $o | tee -a $O/result.txt
        else
          printf "  %-7s tap (%4d,%4d) -> no touch reached the page\n" $via $x $y | tee -a $O/result.txt
        fi
      done
    done
  done
done
rpc display.rotation '{"orientation":"portrait"}' > /dev/null
rpc display.posture '{"hinge":"closed"}' > /dev/null

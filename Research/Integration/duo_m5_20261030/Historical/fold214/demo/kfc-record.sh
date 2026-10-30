#!/bin/zsh
# KFC (com.yum.kfc.brand.prod.enterprise, browse-only, not signed in) on
# duo-m5-fold214: several pages across Duo postures, recorded with the VM
# window's own recorder (Shift-Command-R).
# The app is iPhone-only and portrait-only, so the inner display shows it in a
# compatibility window with a zoom button. input.tap takes cover points
# (466x678); the coordinates below were measured from screenshots:
#   cover: app points 1:1 (375-pt window at the left edge)
#   inner window: x = 103 + 0.694 ax, y = 102 + 0.699 ay; zoom button (433,645)
#   inner zoomed: tab bar y 648; tabs at x 87 / 155 / 281 / 346
#   kfc-record.sh <tag>
set -uo pipefail
TAG=${1:?tag}
T=/Users/kolar/vphone-duo-m5/run/fold214/tools
OUT=/Users/kolar/vphone-duo-m5/run/fold214/demo/$TAG
APP=com.yum.kfc.brand.prod.enterprise
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
tap() { # tap <label> <x> <y> [settle]; retries while vphoned rejects the point mid-transition
  local r i
  for i in 1 2 3 4; do
    r=$($T/rpc.sh input.tap "{\"x\":$2,\"y\":$3}" | jq -c '{ok, error}')
    [[ $r == *'"ok":true'* ]] && break
    log "tap $1 try $i $r screen=$($T/rpc.sh ui.describe | jq -c '.result.screen|[.width,.height,.orientation]')"; /bin/sleep 1
  done
  log "tap $1 $r"; /bin/sleep ${4:-3}
}
swipe() { act "swipe $1" input.swipe "{\"x1\":$2,\"y1\":$3,\"x2\":$4,\"y2\":$5,\"seconds\":0.5}" ${6:-2} }
# has_label <label>: the current UI tree has an element with that label.
has_label() { $T/rpc.sh ui.describe | jq -e --arg l "$1" 'any(.result.elements.elements[]?; .label == $l)' > /dev/null }
# expect <label> [seconds]: wait for a page by one of its labels; log a miss.
expect() {
  local i
  for i in {1..${2:-6}}; do has_label "$1" && { log "page ok: $1"; return 0 }; /bin/sleep 1; done
  log "MISSING page: $1"; return 1
}
# inner_check <label>: the inner display sometimes stays black after an unfold
# until the next posture change (seen in kfc4, 26 s). Screenshot it; if black,
# go open-flat, portrait, open (ends in portrait), and log it.
inner_check() {
  local p=$(print -r -- '{"t":"screenshot"}' | nc -U -w 15 /Users/kolar/.vphone/machines/duo-m5-fold214/vphone.sock | jq -r '.path // empty')
  local y=$(/opt/homebrew/bin/ffmpeg -v error -i "$p" -vf signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=- -f null - | sed -n 's/.*YAVG=//p')
  rm -f "$p"
  if (( ${y%.*} < 5 )); then
    log "BLACK inner after $1 (YAVG $y): open-flat -> portrait -> open"
    act "re-wake open flat" display.posture '{"hinge":"open-flat"}' 2
    act "re-wake portrait" display.rotation '{"orientation":"portrait"}' 2
    act "re-wake open" display.posture '{"hinge":"open"}' 3
  else
    log "inner ok after $1 (YAVG $y)"
  fi
  # Coming back from partially-open can leave the inner display in landscape.
  local o=$($T/rpc.sh ui.describe | jq -r '.result.screen.orientation')
  if [[ $o != 0 ]]; then
    log "inner orientation $o after $1: back to portrait"
    act "re-portrait" display.rotation '{"orientation":"portrait"}' 3
    if [[ $($T/rpc.sh ui.describe | jq -r '.result.screen.orientation') != 0 ]]; then
      act "re-portrait via open-flat" display.posture '{"hinge":"open-flat"}' 2
      act "re-portrait rotate" display.rotation '{"orientation":"portrait"}' 2
      act "re-portrait open" display.posture '{"hinge":"open"}' 3
    fi
  fi
}

$T/rpc.sh screen.unlock '{"timeout":30}' > /dev/null
$T/rpc.sh display.rotation '{"orientation":"portrait"}' > /dev/null
$T/rpc.sh display.posture '{"hinge":"closed"}' > /dev/null
$T/rpc.sh apps.launch "{\"bundle_id\":\"$APP\"}" > /dev/null
/bin/sleep 3
# Start on the home page, no dialog left over from earlier runs.
ui=$($T/rpc.sh ui.describe | jq -c '[.result.elements.elements[]? | .label // ""]')
[[ $ui == *'"到店自取"'* && $ui != *'真的要退出吗'* ]] || { print "app is not on its home page: $ui"; exit 1 }
# Record the VM window itself (title bar, window corners, the screen as shown)
# with winrec (ScreenCaptureKit): a fixed square around the window, so the
# landscape window is not cropped. Stopped with SIGTERM when the sequence ends.
wid=$(swift /Users/kolar/vphone-duo-m5/run/fold214/demo/winid.swift $pid | head -1 | awk '{print $1}')
[[ -n $wid ]] || { print "no VM window id"; exit 1 }
: > $OUT/actions.log
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true"
/Users/kolar/vphone-duo-m5/run/fold214/demo/winrec $wid 600 $OUT/recording.mov > /dev/null & cap=$!
T0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); /bin/sleep 2

# Page navigation happens on the cover, where taps map 1:1. On the inner
# display only swipes, mid-window taps and the zoom button are used: taps near
# the top of the compatibility window (back buttons) do not land reliably.
# The VM has no location, so the store is picked by hand: Shanghai, first store.
# 1. Cover: home page, in-store pickup, pick Shanghai and a store, menu.
tap   "cover 首页" 58 617 3
swipe "cover home down" 187 520 187 220 2
swipe "cover home up" 187 200 187 600 2
tap   "cover 到店自取" 184 268 4
# With a remembered store this opens its menu; otherwise the pickup page asks
# for location and offers 选择餐厅.
if has_label "经典菜单"; then tap "cover store name (选择餐厅)" 128 261 4
else tap "cover 选择餐厅" 187 530 4; fi
expect "收起地图"
tap   "cover 请选择 city" 60 83 3
expect "热门城市"
tap   "cover 上海" 60 244 6
expect "去点餐"
tap   "cover store 迪美购物中心餐厅" 220 480 3
tap   "cover 去点餐" 187 639 6
expect "经典菜单"
swipe "cover menu down" 220 560 220 360 2
tap   "cover 到店专享" 25 438 3
# 2. Unfold on the menu: scroll and switch category in the window, then zoom.
act   "unfold (menu)" display.posture '{"hinge":"open"}' 4
inner_check "unfold (menu)"
swipe "inner menu down" 256 486 256 347 2
tap   "inner 人气热卖" 120 362 3
tap   "inner zoom" 433 645 4
swipe "zoomed menu down" 250 520 250 300 3
# 3. Half open, flat, landscape (no taps: open-flat turns the screen space).
# KFC is portrait-only: on the landscape screen iOS shows it sideways for about
# 1.4 s, then upright and letterboxed. That is the guest's own rendering (its
# screenshots match), so it stays in the video.
act   "partially open" display.posture '{"hinge":"partially-open"}' 3
act   "open flat" display.posture '{"hinge":"open-flat"}' 3
act   "landscape" display.rotation '{"orientation":"landscape-left"}' 4
act   "portrait" display.rotation '{"orientation":"portrait"}' 3
act   "open" display.posture '{"hinge":"open"}' 3
inner_check open
tap   "inner unzoom" 433 645 3
# 4. Fold: the cover takes the menu over; leave ordering, home on both screens.
act   "fold (menu)" display.posture '{"hinge":"closed"}' 4
swipe "cover menu up" 220 360 220 600 2
tap   "cover back" 28 36 2
tap   "cover 退出 (leave ordering)" 259 374 3
expect "到店自取"
act   "unfold (home)" display.posture '{"hinge":"open"}' 4
inner_check "unfold (home)"
tap   "inner 会员中心" 322 533 3
tap   "inner 首页" 143 533 3
act   "fold (home)" display.posture '{"hinge":"closed"}' 3


/bin/sleep 2; kill -TERM $cap; wait $cap
print -r -- "saved $OUT/recording.mov"

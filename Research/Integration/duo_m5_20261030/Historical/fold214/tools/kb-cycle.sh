#!/bin/zsh
# kb-cycle.sh <bundle-id> <tap-x> <tap-y> <tag> : launch on the cover, tap a text
# field, type, confirm focus (keyboard keys in the app's nested AX tree), open,
# close, and report whether the cover still shows the app (visible AX elements).
T=/Users/kolar/vphone-duo-m5/run/fold214/tools
S=/Users/kolar/.vphone/machines/duo-m5-fold214/vphone.sock
O=/Users/kolar/vphone-duo-m5/run/fold214/kb
mkdir -p $O
visible() { $T/rpc.sh ui.describe | jq -r '.result.elements.count // 0' }
keys() { $T/rpc.sh ui.tree '{"nested":true}' | jq -r '[.. | objects | select(has("frame")) | (.label // "") | select(. == "delete" or . == "space" or . == "a")] | length' }
$T/rpc.sh screen.unlock '{"timeout":30}' > /dev/null
$T/rpc.sh display.posture '{"hinge":"closed"}' > /dev/null; /bin/sleep 2
$T/rpc.sh apps.launch "{\"bundle_id\":\"$1\"}" > /dev/null; /bin/sleep 6
if [[ $2 == label ]]; then $T/rpc.sh ui.tap_element "{\"text\":\"$3\",\"match\":\"exact\",\"index\":0}" | jq -c "{tap: .ok, err: .error}"; else $T/rpc.sh input.tap "{\"x\":$2,\"y\":$3}" > /dev/null; fi; /bin/sleep 1
$T/rpc.sh input.type '{"text":"kbtest"}' > /dev/null; /bin/sleep 1
print -r -- "[$4] cover focused: visible=$(visible) keyboard-keys=$(keys)"
$T/rpc.sh display.posture '{"hinge":"open"}' > /dev/null; /bin/sleep 4
print -r -- "[$4] open:           visible=$(visible) keyboard-keys=$(keys)"
$T/rpc.sh display.posture '{"hinge":"closed"}' > /dev/null; /bin/sleep 4
print -r -- "[$4] closed:         visible=$(visible) keyboard-keys=$(keys)"
p=$(print -r -- '{"t":"screenshot"}' | nc -U -w 15 $S | jq -r '.path // empty')
[[ -n $p && -f $p ]] && mv "$p" $O/$4-closed.jpg && sips -Z 400 $O/$4-closed.jpg --out $O/s-$4-closed.jpg > /dev/null

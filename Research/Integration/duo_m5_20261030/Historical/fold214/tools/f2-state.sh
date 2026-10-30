#!/bin/zsh
# f2-state.sh <tag> : food_ordering's state on duo-m5-fold214 — pid, foreground,
# accessibility labels and values, pose, lock — and a screenshot, into run/fold214/f2.
T=/Users/kolar/vphone-duo-m5/run/fold214/tools
S=/Users/kolar/.vphone/machines/duo-m5-fold214/vphone.sock
O=/Users/kolar/vphone-duo-m5/run/fold214/f2
mkdir -p $O
pid=$($T/rpc.sh processes.list | jq -r '[.result.processes[] | select((.name // "")|startswith("FoodAIVerificati")) | .pid][0] // "none"')
fg=$($T/rpc.sh apps.foreground | jq -r '.result.bundle_id // "?"')
hinge=$($T/rpc.sh display.pose | jq -r '.result.hinge')
lock=$($T/rpc.sh device.snapshot | jq -c '.result.lock | {locked, screen_off}')
els=$($T/rpc.sh ui.describe | jq -c '[.result.elements.elements[]? | select((.label // "") != "" or (.value // "") != "") | (.label + (if (.value // "") != "" then "=" + .value else "" end))]')
p=$(print -r -- '{"t":"screenshot"}' | nc -U -w 15 $S | jq -r '.path // empty')
[[ -n $p && -f $p ]] && mv "$p" $O/$1.jpg && sips -Z 600 $O/$1.jpg --out $O/s-$1.jpg > /dev/null
print -r -- "[$1] hinge=$hinge pid=$pid fg=$fg lock=$lock"
print -r -- "    ui=$els"

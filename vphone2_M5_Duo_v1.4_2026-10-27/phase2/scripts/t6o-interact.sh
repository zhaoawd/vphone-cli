#!/bin/zsh
# T6 at the outer size on duo-m5-dd: one fixed interaction round in a windowed
# launch. GeoProbe sample, Safari (open a page, landscape-left and back,
# keyboard input into the address bar), food_ordering, and a background /
# foreground round trip that checks Safari keeps its pid. Each step records the
# foreground app; screenshots under run/t6-outer/interact/.
set -uo pipefail
VM=duo-m5-dd
B=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=/Users/kolar/vphone-duo-m5/run/t6-outer/interact
mkdir -p $OUT
send() { print -r -- "$1" | nc -U -w 60 $S 2>/dev/null || true }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
fg() { rpc apps.foreground | jq -r '.result.bundle_id // "?"' }
pidof() { rpc processes.list | jq -r --arg n "$1" '[.result.processes[] | select(.name==$n) | .pid][0] // "none"' }
shot() { send "{\"t\":\"screenshot\",\"path\":\"$OUT/$1.png\"}" > /dev/null }
step() { print -r -- "$(date +%T) $1" | tee -a $OUT/results.txt }

nohup $B vm launch $VM -v > $OUT/boot.log 2>&1 &
lp=$!
t0=$(date +%s)
while (( $(date +%s) - t0 < 300 )); do
  [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && break
  sleep 2
done
sleep 40
step "unlock: $(rpc screen.unlock '{"timeout":30}' | jq -c '.result | {locked, screen_off}')"

rpc apps.launch '{"bundle_id":"com.autophone.geoprobe"}' > /dev/null; sleep 5; shot geoprobe
step "geoprobe: foreground=$(fg)"

rpc apps.open_url '{"url":"https://example.com"}' > /dev/null; sleep 8; shot safari-page
step "safari open_url: foreground=$(fg) pid=$(pidof MobileSafari)"
safari_pid=$(pidof MobileSafari)
step "rotate landscape-left: $(rpc display.rotation '{"orientation":"landscape-left"}' | jq -c '{ok, name: .result.name, error}')"
sleep 4; shot safari-landscape
step "rotate portrait: $(rpc display.rotation '{"orientation":"portrait"}' | jq -c '{ok, name: .result.name, error}')"
sleep 4

# Keyboard: tap the address field (bottom bar on the outer panel), type, return.
step "address tap: $(rpc input.tap '{"x":233,"y":640}' | jq -c '{ok, error}')"
sleep 2
step "type: $(rpc input.type '{"text":"example.org\n"}' | jq -c '{ok, error}')"
sleep 8; shot safari-typed

food=$(rpc apps.list | jq -r '[.result | (.apps // .) | .[]? | .bundle_id | select(test("food|ordering|autophone.food"; "i"))][0] // empty')
if [[ -n $food ]]; then
  rpc apps.launch "{\"bundle_id\":\"$food\"}" > /dev/null; sleep 8; shot food
  step "food_ordering ($food): foreground=$(fg)"
else
  step "food_ordering: not installed"
fi

rpc input.button '{"name":"home"}' > /dev/null; sleep 3
rpc apps.launch '{"bundle_id":"com.apple.mobilesafari"}' > /dev/null; sleep 5
step "safari back: foreground=$(fg) pid=$(pidof MobileSafari) (was $safari_pid)"
rpc input.button '{"name":"home"}' > /dev/null; sleep 2
step "processes: SB=$(pidof SpringBoard) BB=$(pidof backboardd) vphoned=$(pidof vphoned) launchd_cpu=$(rpc processes.list | jq -r '[.result.processes[] | select(.pid==1) | .cpu_seconds][0]')"
step "crashes since boot: $(rpc logs.crashes | jq -r --argjson t $t0 '[.result.crashes[]? | select(.mtime >= $t) | .process] | group_by(.) | map("\(.[0])=\(length)") | join(" ")')"

$B vm stop $VM > $OUT/stop.log 2>&1
wait $lp 2>/dev/null
step "stopped"

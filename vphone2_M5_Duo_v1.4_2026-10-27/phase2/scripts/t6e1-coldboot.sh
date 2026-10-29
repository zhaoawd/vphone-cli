#!/bin/zsh
# T6 at E1 (2007x2853@430) on duo-m5-dd, frozen candidate, inner cutout patch
# selected. A preparation boot records the candidate (source commit, bundle,
# guest library and vphoned hashes, patch selection and receipt) and turns the
# touch diagnostic off; then N headless cold boots. Per boot: time to vphoned,
# CPU of launchd and kernel_task at 180 s uptime, SpringBoard/backboardd/vphoned
# pids, new crash reports, whether the cutout patch applied this boot, a touch
# check by vphoned (Notes) and by the host view (Maps) with the foreground app
# after each, a screenshot; then a clean stop. Results in run/t6-e1/.
set -uo pipefail
VM=duo-m5-dd
N=${1:-10}
BUNDLE=/Users/kolar/github/vphone-cli-up/.build/pr728-dd/VPhone.bundle
B=$BUNDLE/Contents/MacOS/vphone-cli
S=/Users/kolar/.vphone/machines/$VM/vphone.sock
OUT=/Users/kolar/vphone-duo-m5/run/t6-e1
FIX_LOG=/var/mobile/Library/Caches/vphone-innercutout.log
export VPHONE_SCREEN=2007x2853@430
mkdir -p $OUT/shots $OUT/boot-logs
send() { print -r -- "$1" | nc -U -w 30 $S 2>/dev/null || true }
rpc() { send "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" }
note() { print -r -- "$1" | tee -a $OUT/results.txt }
crashes() { rpc logs.crashes | jq -r '.result.crashes[]? | .name' | sort }
pidof() { print -r -- "$1" | jq -r --arg n "$2" '[.result.processes[] | select(.name==$n) | .pid][0] // "none"' }
sha() { shasum -a 256 "$1" | cut -c1-12 }
applied_lines() { rpc files.read "{\"path\":\"$FIX_LOG\"}" | jq -r '.result.content // ""' | grep -c ' applied #' }
boot() {  # boot <log>; sets lp and ready
  t0=$(date +%s)
  nohup $B vm launch $VM --headless -v > $1 2>&1 &
  lp=$!; ready=""
  while (( $(date +%s) - t0 < 600 )); do
    if [[ -S $S ]] && rpc device.info | jq -e '.ok == true' > /dev/null 2>&1; then
      ready=$(( $(date +%s) - t0 )); break
    fi
    kill -0 $lp 2>/dev/null || break
    sleep 2
  done
}
stopvm() { $B vm stop $VM > $1 2>&1 || note "stop failed ($1)"; wait $lp 2>/dev/null; sleep 5 }

# Candidate record.
note "candidate $(date '+%F %T')"
note "  source: $(git -C /Users/kolar/vphone-duo-m5/src/pr728 log --oneline -1) (worktree clean: $([[ -z $(git -C /Users/kolar/vphone-duo-m5/src/pr728 status --porcelain) ]] && print yes || print no))"
note "  vphone-cli $(sha $B)  vphone-vm $(sha $BUNDLE/Contents/MacOS/vphone-vm)  bundled vphoned $(sha $BUNDLE/Contents/Resources/guest-resources/vphoned)  bundled libinnercutoutfix $(sha $BUNDLE/Contents/Resources/guest-resources/libinnercutoutfix.dylib)"
note "  selection: $(plutil -p /Users/kolar/.vphone/machines/$VM/PatchSelection.plist | tr -s ' \n' ' ')"
note "  receipt Guest has inner_cutout: $(plutil -p /Users/kolar/.vphone/machines/$VM/PatchReceipt.plist | grep -c system-springboard-exp-inner_cutout)"
note "  display: VPHONE_SCREEN=$VPHONE_SCREEN, headless, rotation 0"
boot $OUT/boot-logs/prep.log
if [[ -z $ready ]]; then note "prep boot: vphoned not ready"; exit 1; fi
sleep 20
rpc files.remove '{"path":"/var/mobile/Library/Caches/vphone-touchdiag.flag"}' > /dev/null
rpc files.remove '{"path":"/var/mobile/Library/Caches/vphone-innercutout.flag"}' > /dev/null
note "  guest libraries: $(rpc environment.status | jq -c '[.result.libraries[] | select(.name | test("innercutout|touchdiag|SystemHook")) | {(.name): ((.sha256 // "absent") | .[0:12])}] | add')"
send "{\"t\":\"pull\",\"path\":\"/usr/bin/vphoned\",\"local\":\"$OUT/guest-vphoned\"}" > /dev/null
note "  guest vphoned: $([[ -f $OUT/guest-vphoned ]] && sha $OUT/guest-vphoned || print "not pulled")"
note "  diagnostic flag removed: $(rpc files.read '{"path":"/var/mobile/Library/Caches/vphone-touchdiag.flag"}' | jq -r 'if .ok then "no" else "yes" end')"
crashes > $OUT/crashes-before.txt
stopvm $OUT/boot-logs/prep-stop.log

note "start $(date +%T)"
for i in $(seq 1 $N); do
  boot $OUT/boot-logs/boot-$i.log
  if [[ -z $ready ]]; then
    note "boot $i: vphoned not ready (launch alive: $(kill -0 $lp 2>/dev/null && print yes || print no))"
  else
    before=$(applied_lines)
    while :; do
      up=$(rpc device.info | jq -r '.result.uptime_seconds // 0 | floor')
      (( up >= 180 )) && break
      sleep 5
    done
    ps=$(rpc processes.list)
    ld=$(print -r -- $ps | jq -r '[.result.processes[] | select(.pid==1) | .cpu_seconds | floor][0] // "?"')
    kt=$(print -r -- $ps | jq -r '[.result.processes[] | select(.name=="kernel_task") | .cpu_seconds | floor][0] // "?"')
    pids="SB=$(pidof $ps SpringBoard) BB=$(pidof $ps backboardd) vphoned=$(pidof $ps vphoned)"
    unlock=$(rpc screen.unlock '{"timeout":30}' | jq -r 'if .ok then "ok" else "fail" end')
    sleep 2
    rpc input.button '{"name":"home"}' > /dev/null; sleep 3
    rpc input.button '{"name":"home"}' > /dev/null; sleep 3
    rpc input.tap '{"x":281,"y":465}' > /dev/null; sleep 5
    guest=$(rpc apps.foreground | jq -r '.result.bundle_id // "?"')
    rpc input.button '{"name":"home"}' > /dev/null; sleep 3
    send '{"t":"tap","x":1479,"y":1396,"screen":false}' > /dev/null; sleep 5
    host=$(rpc apps.foreground | jq -r '.result.bundle_id // "?"')
    rpc input.button '{"name":"home"}' > /dev/null; sleep 2
    fix=$(( $(applied_lines) - before ))
    crashes > $OUT/crashes-$i.txt
    new=$(comm -13 $OUT/crashes-before.txt $OUT/crashes-$i.txt | sed -E 's/-[0-9]{4}-.*//' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
    cp $OUT/crashes-$i.txt $OUT/crashes-before.txt
    p=$(send '{"t":"screenshot"}' | jq -r '.path // empty')
    [[ -n $p && -f $p ]] && mv "$p" $OUT/shots/boot-$i.jpg
    note "boot $i: vphoned_ready=${ready}s up=${up}s launchd_cpu=${ld}s kernel_task=${kt}s $pids unlock=$unlock fix_applied_lines=+$fix guest_notes=$guest host_maps=$host new_crashes: ${new:-none}"
  fi
  stopvm $OUT/boot-logs/stop-$i.log
done
note "done $(date +%T)"

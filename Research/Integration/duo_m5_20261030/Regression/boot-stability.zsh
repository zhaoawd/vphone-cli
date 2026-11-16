#!/bin/zsh
# Three sequential cold boots; preserve every failed attempt and restore one fixed baseline.
set -euo pipefail
unsetopt BG_NICE
reg=${0:a:h}
root=${reg:h:h:h:h}
out=${1:?new output directory required}
baseline=${2:?stable baseline directory required}
mode=${3:-reapply}
[[ $mode == reapply || $mode == transition ]]
driver_mode=baseline-stability
[[ $mode == reapply ]] || driver_mode=baseline-stability-transition
[[ $out == "$root/.build/"* && ! -e $out ]]
[[ $baseline == "$root/.build/overall-port-20261116/cold-run."* && -f "$baseline/device.json" ]]
mkdir -p "$out"
machine="$root/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116"
failed=0
printf 'attempt\tcold_run\tdriver_exit\trestore_exit\tfirst_pose\n' > "$out/results.tsv"
for attempt in 1 2 3; do
    log="$out/attempt-$attempt.log"
    zsh "$reg/overall-runtime.zsh" "$driver_mode" > "$log" 2>&1 &
    driver_pid=$!
    cold=""
    deadline=$(( $(date +%s) + 240 ))
    while kill -0 "$driver_pid" 2>/dev/null; do
        if [[ -z $cold && -s $log ]]; then IFS= read -r cold < "$log"; fi
        [[ -z $cold || ! -e "$cold/observations-complete" ]] || break
        (( $(date +%s) <= deadline )) || break
        sleep 1
    done
    restore_result=1
    if [[ $cold == "$root/.build/overall-port-20261116/cold-run."* && -e "$cold/observations-complete" && ! -e "$cold/not-ready" ]]; then
        restore_result=0
        node "$reg/patch-port-runtime-restore.mjs" "$machine/vphone.sock" "$baseline" "$cold/final-settings" > "$cold/final-settings.log" 2>&1 || restore_result=$?
        touch "$cold/stop"
    elif [[ $cold == "$root/.build/overall-port-20261116/cold-run."* && -f "$cold/vm.pid" ]]; then
        vm_pid=$(<"$cold/vm.pid")
        if [[ $vm_pid == <-> ]] && lsof -a -p "$vm_pid" "$machine/Disk.img" > "$cold/failure-handles.txt"; then
            print -r -- 'SIGINT after bounded RPC readiness failure' > "$cold/failure-stop.txt"
            kill -INT "$vm_pid"
        fi
        touch "$cold/stop"
    fi
    driver_result=0
    wait "$driver_pid" || driver_result=$?
    first_pose=failed
    [[ ! -e "$cold/first-pose/summary.json" ]] || first_pose=passed
    printf '%s\t%s\t%s\t%s\t%s\n' "$attempt" "$cold" "$driver_result" "$restore_result" "$first_pose" >> "$out/results.tsv"
    print -r -- "attempt $attempt: driver=$driver_result restore=$restore_result first_pose=$first_pose $cold"
    if (( driver_result || restore_result )) || [[ $first_pose != passed ]]; then failed=$((failed+1)); fi
    if lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/handles-after-$attempt.txt"; then
        print -u2 'Target still has state handles; stop before another boot'
        exit 1
    fi
done
print -r -- "$failed" > "$out/failed-attempts.txt"
(( failed == 0 ))

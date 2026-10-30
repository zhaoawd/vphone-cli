#!/bin/zsh
# F6 snapshot round trip on a disposable machine in the acceptance library
# (for example the imported copy). Takes `pre`, boots and writes a marker
# file in the guest, takes `marked`, reverts to `pre` and checks the marker is
# gone, then reverts to `marked` and checks it is back. Every boot checks
# vphoned, unlock, a fold through the inner display and SpringBoard's PID.
# Snapshots are left in place for inspection.
#   f6-snapshot.zsh <baseline|candidate> <machine> <new-output-directory>
set -uo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: f6-snapshot.zsh <baseline|candidate> <machine> <new-output-directory>}"
machine="${2:?machine required}"
output_root="${3:?new evidence directory required}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
# Never the clones other runs depend on.
[[ "$machine" == [a-zA-Z0-9]* && "$machine" != *[^a-zA-Z0-9_-]* && "$machine" != duo-$variant-20261030 && "$machine" != seed ]] || exit 2
case "$variant" in
    baseline) bundle="$repo_root/.build/validation/baseline/artifacts/VPhone.bundle" ;;
    candidate) bundle="$repo_root/.build/XcodeDuo/Build/Products/Debug/VPhone.bundle" ;;
esac
cli="$bundle/Contents/MacOS/vphone-cli"
library="$repo_root/.build/acceptance/machines"
socket_path="$library/$machine/vphone.sock"
[[ -d "$library/$machine" && "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
zsh "${0:a:h}/vm-run.zsh" "$variant" preflight --check > /dev/null || exit 1
pgrep -f "vphone-vm.*/$machine" > /dev/null && { print -u2 "$machine is running"; exit 2; }
mkdir -p "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"

rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")" 2>/dev/null; }
note() { print -r -- "$1" | tee -a "$output_root/results.txt"; }
marker=/var/mobile/Documents/duo-snapshot-marker.txt
marker_text="duo snapshot $(date -u +%FT%TZ)"
launch_pid=""
boot() {
    "$cli" vm launch "$machine" -l "$library" --headless -v > "$output_root/boot-$1.log" 2>&1 &
    launch_pid=$!
    local t0=$(date +%s)
    while (( $(date +%s) - t0 < 300 )); do
        rpc device.info | jq -e '.ok == true' > /dev/null 2>&1 && break
        kill -0 $launch_pid 2>/dev/null || return 1
        /bin/sleep 2
    done
    /bin/sleep 45
}
stop() { "$cli" vm stop "$machine" -l "$library" > "$output_root/stop-$1.log" 2>&1; wait $launch_pid; /bin/sleep 3; }
check() { # check <label>: unlock, fold, SpringBoard PID, marker
    local unlock sb1 sb2 shown content
    unlock=$(rpc screen.unlock '{"timeout":30}' | jq -r 'if .ok then "ok" else "fail" end')
    sb1=$(rpc processes.list | jq -r '[.result.processes[]|select(.name=="SpringBoard")|.pid][0]')
    rpc display.posture '{"hinge":"open-flat"}' > /dev/null; /bin/sleep 4
    shown=$(rpc device.screen | jq -r '.result | "\(.width)x\(.height)"')
    rpc display.posture '{"hinge":"closed"}' > /dev/null; /bin/sleep 4
    sb2=$(rpc processes.list | jq -r '[.result.processes[]|select(.name=="SpringBoard")|.pid][0]')
    content=$(rpc files.read "$(jq -nc --arg p $marker '{path:$p}')" | jq -r '.result.content // "absent"')
    note "$1: unlock=$unlock open=$shown SB=$sb1/$sb2 marker=$content"
}
# Revert asks before replacing the disk; this machine is disposable by contract.
snapshot() {
    local force=()
    [[ "$1" == revert ]] && force=(--force)
    "$cli" vm snapshot "$1" "$machine" "$2" -l "$library" $force >> "$output_root/snapshot.log" 2>&1 \
        || { note "snapshot $1 $2 failed"; exit 1; }
}

snapshot create pre
boot 1 || { note "boot 1 failed"; exit 1; }
check "before marker"
rpc files.write "$(jq -nc --arg p $marker --arg c "$marker_text" '{path:$p,content:$c}')" > "$output_root/write.json"
check "after marker"
stop 1
snapshot create marked
snapshot revert pre
boot 2 || { note "boot 2 failed"; exit 1; }
check "reverted to pre (marker expected absent)"
stop 2
snapshot revert marked
boot 3 || { note "boot 3 failed"; exit 1; }
check "reverted to marked (marker expected: $marker_text)"
stop 3
"$cli" vm snapshot list "$machine" -l "$library" > "$output_root/snapshots.txt" 2>&1
note "done $(date '+%F %T')"

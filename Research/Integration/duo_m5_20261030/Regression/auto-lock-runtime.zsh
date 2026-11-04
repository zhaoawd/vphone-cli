#!/bin/zsh
# Finite and Never timers, profiled restart, and cold-boot persistence.
# Changes Auto-Lock only on the disposable Duo acceptance guest.
set -euo pipefail
source "${0:a:h}/host-request.zsh"
source "${0:a:h}/rpc-request.zsh"
repo="${0:a:h:h:h:h:h}"
socket="${1:?usage: auto-lock-runtime.zsh <acceptance-socket> <evidence-directory> <observe|profiled|after-reboot>}"
out="${2:?evidence directory required}"
mode="${3:?observe, profiled, or after-reboot required}"
[[ "$socket" == "$repo/.build/"* && -S "$socket" && "$out" == "$repo/.build/"* ]]
rpc() { vphone_host_request "$socket" "$(vphone_rpc_request "$@")"; }
guest_dir=/var/mobile/Library/UserConfigurationProfiles
prefs() {
    local label="$1" leaf
    rpc display.auto_lock > "$out/$label-readback.json"
    rpc files.list "{\"path\":\"$guest_dir\"}" > "$out/$label-files.json"
    for leaf in UserSettings EffectiveUserSettings; do
        vphone_host_request "$socket" "$(jq -nc --arg p "$guest_dir/$leaf.plist" --arg l "$out/$label-$leaf.plist" \
            '{t:"pull",path:$p,local:$l}')" > "$out/$label-$leaf-pull.json"
        plutil -extract restrictedValue.maxInactivity json -o "$out/$label-$leaf-maxInactivity.json" "$out/$label-$leaf.plist"
    done
}
has_value() {
    local label="$1" expected="$2"
    jq -e --argjson n "$expected" '.result.auto_lock_seconds==$n and .result.never==($n==2147483647)' "$out/$label-readback.json" >/dev/null &&
        jq -se --argjson n "$expected" 'length==2 and all(.[]; .value==$n)' "$out/$label-"*-maxInactivity.json >/dev/null
}
new_device_info() {
    rpc device.info > "$1"
    jq -e '.result.device_name.name=="duo-sync-ax-idle"' "$1" >/dev/null
}
if [[ "$mode" == after-reboot ]]; then
    [[ -f "$out/device-before.json" && ! -e "$out/device-after-reboot.json" ]]
    new_device_info "$out/device-after-reboot.json"
    jq -se '.[0].result.boot_session_uuid!=.[1].result.boot_session_uuid and
        .[0].result.agent.binary_hash==.[1].result.agent.binary_hash' "$out/device-before.json" "$out/device-after-reboot.json" > "$out/reboot-verdict.json"
    prefs after-reboot
    has_value after-reboot 2147483647
    jq -e '.result.lock_screen_minimum_seconds==2147483647' "$out/after-reboot-readback.json" > "$out/reboot-never-verdict.json"
    print 'Never persisted across cold boot in both plists and the RPC readback.'
    exit 0
fi
[[ ( "$mode" == observe || "$mode" == profiled ) && ! -e "$out" ]]
mkdir "$out"
cp "${0:a}" "$out/driver.zsh"
git -C "$repo" rev-parse HEAD > "$out/source-sha.txt"
new_device_info "$out/device-before.json"

sample() {
    local label="$1" elapsed="$2"
    rpc device.screen | jq -c --argjson elapsed "$elapsed" '{elapsed_s:$elapsed,locked:.result.locked,screen_off:.result.screen_off}' >> "$out/$label-samples.jsonl"
}
observe_finite() {
    local start elapsed
    rpc display.auto_lock.set '{"seconds":30}' > "$out/finite-set.json"
    jq -e '.result.auto_lock_seconds==30 and .result.never==false' "$out/finite-set.json" >/dev/null || return 1
    prefs finite
    has_value finite 30 || return 1
    rpc screen.unlock '{"timeout":30}' > "$out/finite-unlock.json"
    rpc input.button '{"name":"home"}' > "$out/finite-last-input.json"
    start=$SECONDS
    while (( (elapsed=SECONDS-start) <= 50 )); do
        sample finite "$elapsed"
        if tail -1 "$out/finite-samples.jsonl" | jq -e '.locked==true' >/dev/null; then break; fi
        sleep 2
    done
    jq -se 'length>1 and .[0].locked==false and .[0].screen_off==false and
        .[-1].locked==true and .[-1].elapsed_s>=25 and .[-1].elapsed_s<=45' "$out/finite-samples.jsonl" > "$out/finite-verdict.json"
}
observe_never() {
    local start elapsed
    rpc screen.unlock '{"timeout":30}' > "$out/never-unlock.json"
    rpc display.auto_lock.set '{"never":true}' > "$out/never-set.json"
    jq -e '.result.auto_lock_seconds==2147483647 and .result.never and .result.lock_screen_minimum_seconds==2147483647' "$out/never-set.json" >/dev/null || return 1
    prefs never
    has_value never 2147483647 || return 1
    rpc input.button '{"name":"home"}' > "$out/never-last-input.json"
    start=$SECONDS
    while true; do
        elapsed=$((SECONDS-start))
        sample never "$elapsed"
        tail -1 "$out/never-samples.jsonl" | jq -e '.locked==false and .screen_off==false' >/dev/null || return 1
        (( elapsed < 330 )) || break
        sleep 5
    done
    jq -se 'length>1 and .[-1].elapsed_s>=330 and all(.[]; .locked==false and .screen_off==false)' "$out/never-samples.jsonl" > "$out/never-verdict.json"
}
observe_profiled() {
    local before_pid after_pid i
    prefs before-profiled
    rpc processes.list '{"filter":"profiled"}' > "$out/profiled-before.json"
    before_pid=$(jq -er '[.result.processes[] | select(.name=="profiled" and .pid>1)] | select(length==1) | .[0].pid' "$out/profiled-before.json") || return 1
    rpc processes.kill "{\"pid\":$before_pid,\"signal\":\"TERM\",\"force\":true}" > "$out/profiled-terminate.json" || return 1
    for i in {1..20}; do
        rpc processes.list '{"filter":"profiled"}' > "$out/profiled-after.json"
        if jq -e --argjson before "$before_pid" 'any(.result.processes[]; .name=="profiled" and .pid>1 and .pid!=$before)' "$out/profiled-after.json" >/dev/null; then break; fi
        if (( i == 4 )); then rpc apps.launch '{"bundle_id":"com.apple.Preferences"}' > "$out/profiled-settings.json"; fi
        if (( i == 8 )) &&
           jq -e --argjson before "$before_pid" 'any(.result.processes[]; .name=="profiled" and .pid==$before)' "$out/profiled-after.json" >/dev/null; then
            rpc processes.kill "{\"pid\":$before_pid,\"signal\":\"KILL\",\"force\":true}" > "$out/profiled-kill.json" || return 1
        fi
        if (( i == 12 )); then rpc apps.launch '{"bundle_id":"com.apple.Preferences"}' > "$out/profiled-settings-after-kill.json"; fi
        sleep 1
    done
    after_pid=$(jq -er --argjson before "$before_pid" '[.result.processes[] | select(.name=="profiled" and .pid>1 and .pid!=$before)] | select(length==1) | .[0].pid' "$out/profiled-after.json") || return 1
    sleep 5
    prefs after-profiled
    has_value after-profiled 2147483647 || return 1
    jq -n --argjson before "$before_pid" --argjson after "$after_pid" --slurpfile a "$out/before-profiled-files.json" --slurpfile b "$out/after-profiled-files.json" '
        def effective($x): $x[0].result.entries[] | select(.name=="EffectiveUserSettings.plist") | .mtime;
        {pid_before:$before,pid_after:$after,effective_mtime_before:effective($a),effective_mtime_after:effective($b),effective_mtime_changed:(effective($a)!=effective($b))}' > "$out/profiled-verdict.json"
}
if [[ "$mode" == profiled ]]; then
    observe_profiled
    print 'Never persisted across profiled restart; see file timestamp evidence.'
    exit 0
fi
prefs baseline
rpc power.low_power_mode '{"enabled":false}' > "$out/low-power.json"
jq -e '.result.enabled==false' "$out/low-power.json" >/dev/null
rpc screen.unlock '{"timeout":30}' > "$out/unlock-initial.json"
rpc display.posture '{"hinge":"closed"}' > "$out/posture.json"
rpc display.rotation '{"orientation":"portrait"}' > "$out/rotation.json"
failed=0
if observe_finite; then print '30 s Auto-Lock passed.'; else print -u2 '30 s Auto-Lock failed.'; failed=1; fi
if observe_never; then print 'Never stayed awake for at least 330 s.'; else print -u2 'Never idle check failed.'; failed=1; fi
if observe_profiled; then print 'Never persisted across profiled restart; see file timestamp evidence.'; else print -u2 'profiled restart or persistence was not verified.'; failed=1; fi
(( failed == 0 ))

#!/bin/zsh
# Exercise Home Screen AX in a disposable, running Duo.
set -euo pipefail
source "${0:a:h}/host-request.zsh"
source "${0:a:h}/rpc-request.zsh"
repo="${0:a:h:h:h:h:h}"
socket="${1:?usage: home-screen-ax.zsh <acceptance-socket> <new-evidence-directory>}"
out="${2:?new evidence directory required}"
[[ "$socket" == "$repo/.build/"* && -S "$socket" && "$out" == "$repo/.build/"* && ! -e "$out" ]]
mkdir "$out"
rpc() { vphone_host_request "$socket" "$(vphone_rpc_request "$@")"; }
rpc device.info > "$out/device.json"
jq -e '.result.device_name.name == "duo-sync-ax" or .result.device_name.name == "duo-sync-ax-idle"' "$out/device.json" >/dev/null
rpc screen.unlock '{"timeout":30}' > "$out/unlock.json"
rpc input.button '{"name":"home"}' > "$out/initial-home.json"
sleep 2
rpc ui.tree > "$out/initial-tree.json"
if jq -e 'any(.result.elements[]; .identifier=="com.apple.lockdown.ax.trust.deny_trust")' "$out/initial-tree.json" >/dev/null; then
    rpc ui.tap_element '{"identifier":"com.apple.lockdown.ax.trust.deny_trust","match":"exact"}' > "$out/trust-denied.json"
fi
rpc power.low_power_mode > "$out/low-power-before.json"
original_power=$(jq -cr '.result.enabled | if type=="boolean" then . else error("missing power state") end' "$out/low-power-before.json")
restore_power() { rpc power.low_power_mode "{\"enabled\":$original_power}" > "$out/low-power-restored.json"; }
trap restore_power EXIT
failed=0

for posture in closed open-flat; do
    d="$out/$posture"
    mkdir "$d"
    rpc display.posture "{\"hinge\":\"$posture\"}" > "$d/posture.json"
    rpc display.rotation '{"orientation":"portrait"}' > "$d/rotation.json"
    rpc input.button '{"name":"home"}' > "$d/home.json"
    sleep 2
    rpc apps.foreground > "$d/home-front.json"
    jq -e '.result.bundle_id=="com.apple.springboard" and .result.verified and .result.pid>1' "$d/home-front.json" >/dev/null
    rpc ui.tree > "$d/tree.json"
    jq -e '[.result.elements[] | select(.identifier=="Settings" and .visible and .clickable)] | select(length==1) | .[0] | {x,y}' "$d/tree.json" > "$d/point.json"
    if ! rpc ui.element_at "$(cat "$d/point.json")" > "$d/element-at.json" 2> "$d/element-at-error.json" ||
       ! jq -e '.result.element | select(.identifier=="Settings" or .label=="Settings")' "$d/element-at.json" >/dev/null; then
        print -u2 "$posture: Settings hit test failed"
        failed=1
    fi
    if ! rpc ui.tap_element '{"identifier":"Settings","match":"exact"}' > "$d/tap.json" 2> "$d/tap-error.json" ||
       ! jq -e '.result.tapped and .result.element.identifier=="Settings"' "$d/tap.json" >/dev/null; then
        print -u2 "$posture: Settings element tap failed"
        failed=1
        continue
    fi
    for i in {1..12}; do
        rpc apps.foreground > "$d/tapped-front.json"
        if jq -e '.result.bundle_id=="com.apple.Preferences" and .result.verified' "$d/tapped-front.json" >/dev/null; then break; fi
        sleep .5
    done
    if ! jq -e '.result.bundle_id=="com.apple.Preferences" and .result.verified' "$d/tapped-front.json" >/dev/null; then
        print -u2 "$posture: Settings did not become foreground"
        failed=1
    fi
done

rpc display.posture '{"hinge":"closed"}' > "$out/final-closed.json"
rpc input.button '{"name":"home"}' > "$out/home-before-lock.json"
rpc power.low_power_mode '{"enabled":true}' > "$out/low-power-for-dark.json"
jq -e '.result.enabled==true' "$out/low-power-for-dark.json" >/dev/null
sleep 3
rpc input.button '{"name":"power"}' > "$out/lock.json"
reject() {
    local label="$1" method="$2"; shift 2
    if rpc "$method" "$@" > "$out/$label-$method-success.json" 2> "$out/$label-$method-rejection.json"; then
        print -u2 "Unexpected success: $label $method"
        return 1
    fi
    jq -se 'length==1 and .[0].ok==false and (.[0].error|test("verify|verified";"i"))' "$out/$label-$method-rejection.json" >/dev/null
}
check_rejections() {
    local label="$1"
    reject "$label" ui.tree
    reject "$label" ui.element_at "$(cat "$out/closed/point.json")"
    reject "$label" ui.tap_element '{"identifier":"Settings","match":"exact"}'
}
for i in {1..20}; do
    rpc device.screen > "$out/dark-screen.json"
    rpc display.orientation > "$out/dark-orientation.json"
    if jq -e '.result.locked and .result.screen_off' "$out/dark-screen.json" >/dev/null &&
       jq -e '.result.screen_off==true' "$out/dark-orientation.json" >/dev/null; then break; fi
    sleep 1
done
jq -e '.result.locked and .result.screen_off' "$out/dark-screen.json" >/dev/null
jq -e '.result.screen_off==true' "$out/dark-orientation.json" >/dev/null
check_rejections dark
rpc input.button '{"name":"power"}' > "$out/light-lock-screen.json"
for i in {1..10}; do
    rpc device.screen > "$out/lit-lock-screen.json"
    if jq -e '.result.locked and (.result.screen_off==false)' "$out/lit-lock-screen.json" >/dev/null; then break; fi
    sleep .2
done
jq -e '.result.locked and (.result.screen_off==false)' "$out/lit-lock-screen.json" >/dev/null
check_rejections lit-locked
rpc screen.unlock '{"timeout":30}' > "$out/final-unlock.json"
print 'AX rejected the lit and dark Lock Screen.'
(( failed == 0 )) || exit 1
print 'Home Screen AX passed on both panels.'

#!/bin/zsh
# F5: record a windowed acceptance VM with its own recorder (Capture > Start
# Recording, the presentation graphics output) while a fixed fold, rotation,
# app and power sequence runs through vphoned. Every action is logged with its
# host time offset from the recording request for later frame alignment.
# Ported from the v1.6 run/fold214/f5-record.sh. The menu item is pressed
# through Accessibility, so no keystrokes reach whichever app is frontmost.
#   f5-record.zsh <baseline|candidate> <new-output-directory>
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: f5-record.zsh <baseline|candidate> <new-output-directory>}"
output_root="${2:?new evidence directory required}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
machine="duo-$variant-20261030"
socket_path="$repo_root/.build/acceptance/machines/$machine/vphone.sock"
[[ -S "$socket_path" && "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
vm_pid=$(pgrep -f "vphone-vm.*$machine" | head -1) || true
[[ -n "$vm_pid" ]] || { print -u2 "No windowed vphone-vm process for $machine"; exit 1; }
mkdir -p "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"
actions="$output_root/actions.tsv"

rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }

# The Capture menu is the one whose first item is Shift-Command-R; its title
# is localized, so it is found by key equivalent rather than by name.
recorder() { # recorder state|press
    osascript - "$vm_pid" "$1" <<'EOF'
on run argv
    set vmPid to (item 1 of argv) as integer
    tell application "System Events" to tell (first process whose unix id is vmPid)
        repeat with barItem in menu bar items of menu bar 1
            try
                set firstItem to menu item 1 of menu 1 of barItem
                if (value of attribute "AXMenuItemCmdChar" of firstItem) is in {"r", "R"} then
                    -- The item is retitled once pressed; read its name first.
                    set itemName to name of firstItem
                    if (item 2 of argv) is "press" then click firstItem
                    return itemName
                end if
            end try
        end repeat
    end tell
    error "Capture menu not found"
end run
EOF
}
# The "Saved to" alert is a sheet on the VM window; its default button is OK.
dismiss_alert() {
    osascript - "$vm_pid" <<'EOF'
on run argv
    set vmPid to (item 1 of argv) as integer
    tell application "System Events" to tell (first process whose unix id is vmPid)
        repeat 10 times
            repeat with w in windows
                if (count of sheets of w) > 0 then
                    set message to value of static text 2 of sheet 1 of w
                    click (value of attribute "AXDefaultButton" of sheet 1 of w)
                    return message
                end if
            end repeat
            delay 0.5
        end repeat
    end tell
    error "No recording alert"
end run
EOF
}
act() { # act <label> <method> [params] [settle-seconds]
    local t reply
    t=$(now)
    # A refused request prints its reply on stderr; keep the row on one line.
    reply=$(rpc "$2" "${3:-{\}}" 2>&1 | tail -1 | jq -c '{ok, error}' 2>/dev/null) || reply='{"ok":false}'
    reply=${reply//$'\n'/}
    printf "%.3f\t%s\t%s\t%.3f\n" $(( t - t0 )) "$1" "$reply" "$t" | tee -a "$actions"
    /bin/sleep "${4:-4}"
}

# Screen on, unlocked, closed, on the cover's Home screen before recording.
rpc screen.unlock '{"timeout":30}' > "$output_root/unlock.json"
rpc display.posture '{"hinge":"closed"}' > /dev/null
rpc input.button '{"name":"home"}' > /dev/null
/bin/sleep 3
idle_title=$(recorder state)
print -r -- "$idle_title" > "$output_root/recorder-idle-title.txt"
rpc logs.crashes > "$output_root/crashes-before.json"
rpc processes.list | jq -c '[.result.processes[]|select(.name=="SpringBoard" or .name=="backboardd")|{name,pid}]|sort_by(.name)' > "$output_root/processes-before.json"

before=$(/bin/ls -t ~/Desktop | grep -E '^vphone-recording' | head -1 || true)
t0=$(now)
recorder press > /dev/null
/bin/sleep 1
print -r -- "$t0" > "$output_root/t0.txt"
recording_title=$(recorder state)
[[ "$recording_title" != "$idle_title" ]] || { print -u2 "Recorder did not start"; exit 1; }
: > "$actions"

act baseline-closed display.posture '{"hinge":"closed"}' 3
for i in 1 2 3 4 5 6; do
    act "home-open-$i" display.posture '{"hinge":"open"}'
    act "home-close-$i" display.posture '{"hinge":"closed"}'
done
act safari-launch-cover apps.launch '{"bundle_id":"com.apple.mobilesafari"}' 5
act safari-open display.posture '{"hinge":"open"}'
act safari-close display.posture '{"hinge":"closed"}'
act safari-open-2 display.posture '{"hinge":"open"}'
act home-inner input.button '{"name":"home"}'
act settings-launch-inner apps.launch '{"bundle_id":"com.apple.Preferences"}' 5
act home-inner-2 input.button '{"name":"home"}'
act photos-launch-inner apps.launch '{"bundle_id":"com.apple.mobileslideshow"}' 5
act photos-close display.posture '{"hinge":"closed"}'
act home-cover input.button '{"name":"home"}'
act rotate-cover-left display.rotation '{"orientation":"landscape-left"}'
act rotate-cover-portrait display.rotation '{"orientation":"portrait"}'
# Only open-flat has unambiguous panel orientations; plain open refuses rotation.
act rotate-open-flat display.posture '{"hinge":"open-flat"}'
act rotate-inner-portrait display.rotation '{"orientation":"portrait"}'
act rotate-inner-landscape display.rotation '{"orientation":"landscape-left"}'
for i in 1 2 3 4; do
    act "rapid-close-$i" display.posture '{"hinge":"closed"}' 1
    act "rapid-open-$i" display.posture '{"hinge":"open"}' 1
done
# Power during a hand-over: the lock screen must show, not the app's last frame.
act safari-launch-inner apps.launch '{"bundle_id":"com.apple.mobilesafari"}' 5
act power-close display.posture '{"hinge":"closed"}' 0.1
act power-after-close input.button '{"name":"power"}' 4
act power-open-dark display.posture '{"hinge":"open"}' 4
act final-close display.posture '{"hinge":"closed"}' 4

recorder press > /dev/null
/bin/sleep 3
rec=""
for _ in {1..20}; do
    rec=$(/bin/ls -t ~/Desktop | grep -E '^vphone-recording' | head -1 || true)
    [[ -n "$rec" && "$rec" != "$before" ]] && break
    /bin/sleep 1
done
dismiss_alert > "$output_root/alert.txt"
[[ -n "$rec" && "$rec" != "$before" ]] || { print -u2 "No new recording"; exit 1; }
mv ~/Desktop/"$rec" "$output_root/recording.mov"
rpc screen.unlock '{"timeout":30}' > "$output_root/unlock-after.json" || true
rpc logs.crashes > "$output_root/crashes-after.json"
rpc processes.list | jq -c '[.result.processes[]|select(.name=="SpringBoard" or .name=="backboardd")|{name,pid}]|sort_by(.name)' > "$output_root/processes-after.json"
rpc files.read '{"path":"/var/mobile/Library/Caches/vphone-folddisplay.log"}' > "$output_root/folddisplay-file.json"
jq -r '.result.content' "$output_root/folddisplay-file.json" > "$output_root/folddisplay.log"
cmp -s "$output_root/processes-before.json" "$output_root/processes-after.json" \
    || print -u2 "SpringBoard/backboardd PIDs changed"
print "Recording: $output_root/recording.mov"

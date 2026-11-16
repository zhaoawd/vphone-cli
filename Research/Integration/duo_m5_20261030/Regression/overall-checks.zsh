#!/bin/zsh
set -euo pipefail
root=${0:a:h:h:h:h:h}
reg=${0:a:h}
out=${1:?usage: overall-checks.zsh <ready cold-run directory>}
out=${out:A}
[[ $out == "$root/.build/overall-port-20261116/cold-run."* && -e "$out/observations-complete" ]]
[[ ! -e "$out/check-failed" && ! -e "$out/not-ready" && ! -e "$out/checks-status.tsv" ]]
socket="$root/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116/vphone.sock"
bundle="$root/.build/overall-port-20261116/REVIEWED/VPhone.bundle"
probe="$root/.build/upstream-port-20261116/remap-probe-exec-identity"
node "$reg/overall-candidate.mjs" > "$out/candidate-before-checks.json"
expected=$(shasum -a 256 "$bundle/Contents/Resources/guest-resources/vphoned")
expected=${expected%% *}
run_check() {
    local label=$1
    shift
    local result=0
    "$@" > "$out/$label.log" 2>&1 || result=$?
    printf '%s\t%s\n' "$label" "$result" >> "$out/checks-status.tsv"
    print -r -- "$label: exit $result"
}
run_check prepare node "$reg/overall-prepare.mjs" "$socket" "$out/prepare" "$expected"
run_check native-input node "$reg/patch-port-native-input.mjs" "$socket" "$out/native-input" "$expected"
run_check ax-context node "$reg/three-issues-ax.mjs" "$socket" "$out/ax-context" "$expected"
run_check orientation node "$reg/followup-orientation.mjs" "$socket" "$out/orientation" com.apple.mobilesafari "$expected"
# These original aggregate assertions remain failures if the inherited limits persist.
run_check ax-discovery node "$reg/patch-port-touch.mjs" "$socket" "$out/ax-discovery" "$expected"
run_check remap node "$reg/txm-remap-runtime.mjs" "$socket" "$out/remap" "$probe" "$bundle" run
if [[ -e "$out/remap/app.json" ]]; then
    run_check standalone-exec node "$reg/txm-standalone-runtime.mjs" "$socket" "$out/standalone-exec" "$out/remap/app.json" "$probe" exec-env
fi
run_check final-settings node "$reg/patch-port-runtime-restore.mjs" "$socket" "$out" "$out/final-settings"
if [[ ! -e "$out/final-settings/device-restored.json" || ! -e "$out/final-settings/pose-restored.json" ]] ||
    [[ $(tail -n 1 "$out/checks-status.tsv") != $'final-settings\t0' ]]; then
    touch "$out/restoration-failed"
    print -u2 'Baseline restoration failed; retain the running guest for evidence and recovery.'
    exit 1
fi
touch "$out/stop"

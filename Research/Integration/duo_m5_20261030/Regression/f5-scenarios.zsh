#!/bin/zsh
# Measure one scenario on a windowed, disposable Duo. Results include
# presentation samples and independent guest panel-ownership evidence.
set -euo pipefail
reg="${0:a:h}"
source "$reg/host-request.zsh"
source "$reg/rpc-request.zsh"
socket="${1:?usage: f5-scenarios.zsh <vphone.sock> <new output> <vphoned SHA-256> <safari|sweep-06|sweep-15|aod|aod-hinge-only>}"
out="${2:?new output required}"
expected="${3:?expected daemon SHA-256 required}"
pose_args=(--match-panel-orientation)
case "${4:-}" in
    safari) scenario_args=(--app=com.apple.mobilesafari) ;;
    sweep-06) scenario_args=(--sweep=0.6) ;;
    sweep-15) scenario_args=(--sweep=1.5) ;;
    aod) scenario_args=(--aod) ;;
    aod-hinge-only) scenario_args=(--aod); pose_args=() ;;
    *) print -u2 'Expected safari, sweep-06, sweep-15, aod or aod-hinge-only'; exit 2 ;;
esac
[[ ! -e "$out" ]] || exit 2
sample_status=0
node "$reg/f5-clock.mjs" "$socket" "$out" "$expected" \
    --settle=2400 --observe=1800 "${pose_args[@]}" "${scenario_args[@]}" portrait || sample_status=$?
[[ -d "$out" ]] || exit "$sample_status"
vphone_host_request "$socket" "$(vphone_rpc_request files.read \
    '{"path":"/var/mobile/Library/Caches/vphone-folddisplay.log","limit":4194304}')" \
    | jq -er '.result | select(.truncated == false and .encoding == "utf8") | .content' > "$out/folddisplay.log"
node "$reg/f5-clock-report.mjs" "$out" > "$out/black.tsv"
node "$reg/f5-handoff-report.mjs" "$out" "$out/folddisplay.log" --require-handoff > "$out/handoff.tsv"
exit "$sample_status"

#!/bin/zsh
# Run against the token-protected loopback API of an isolated acceptance VM.
set -euo pipefail

root="$(cd "${0:a:h}/../../../.." && pwd)"
launch_log="${1:?usage: rpc-stability-runtime.zsh <launch-log> <expected-daemon-sha256> <new-evidence-directory>}"
expected="${2:?expected daemon SHA-256 required}"
out="${3:?new evidence directory required}"
out="${out:A}"
[[ "$out" == "$root/.build/"* && ! -e "$out" && ${#expected} == 64 && "$expected" != *[^0-9a-f]* ]]
base=$(sed -n 's/^\[api\] HTTP\/WebSocket API: //p' "$launch_log" | tail -1)
[[ "$base" == http://127.0.0.1:<-> ]]
token=$(sed -n 's/^\[api\] token: //p' "$launch_log" | tail -1)
[[ ${#token} == 64 && "$token" != *[^0-9a-f]* ]]
mkdir -m 700 "$out"
headers=$(mktemp)
trap 'rm -f "$headers"' EXIT
printf 'Authorization: Bearer %s\n' "$token" > "$headers"
unset token

request() {
    local label="$1" status_wanted="$2" status_actual
    shift 2
    status_actual=$(curl -sS --max-time 20 -H "@$headers" \
        -o "$out/$label.json" -w '%{http_code}' "$@")
    print -r -- "$label $status_actual" >> "$out/status.txt"
    [[ "$status_actual" == "$status_wanted" ]]
}
rpc() {
    request "$1" "$2" -H 'Content-Type: application/json' --data-binary "$3" "$base/v1/rpc"
}

request health-before 200 "$base/v1/health"
jq -e --arg expected "$expected" '.binary_hash == $expected' "$out/health-before.json" >/dev/null
for ((i = 1; i <= 30; i++)); do
    request "health-sequential-$i" 200 "$base/v1/health"
    jq -e --arg expected "$expected" '.binary_hash == $expected' "$out/health-sequential-$i.json" >/dev/null
done
pids=()
for ((i = 1; i <= 12; i++)); do
    request "health-parallel-$i" 200 "$base/v1/health" &
    pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done
for ((i = 1; i <= 12; i++)); do
    jq -e --arg expected "$expected" '.binary_hash == $expected' "$out/health-parallel-$i.json" >/dev/null
done

rpc missing-setting-value 400 '{"method":"settings.set","params":{"domain":"com.vphone.acceptance","key":"probe","type":"string"}}'
rpc null-setting-value 400 '{"method":"settings.set","params":{"domain":"com.vphone.acceptance","key":"probe","value":null}}'
rpc scalar-setting-json 400 '{"method":"settings.set","params":{"domain":"com.vphone.acceptance","key":"probe","type":"json","value":5}}'
for label in missing-setting-value null-setting-value scalar-setting-json; do
    jq -e '.error.message | contains("value is required")' "$out/$label.json" >/dev/null
done
request websocket-bad-version 426 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 12' "$base/v1/events"
request websocket-missing-key 426 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' "$base/v1/events"
request websocket-origin 403 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' \
    -H 'Origin: http://example.invalid' "$base/v1/events"

rpc methods-list 200 '{"method":"methods.list","params":{}}'
jq -e '.result.scope == "duo_display" and .result.complete == false and (.result.methods | length == 12)' "$out/methods-list.json" >/dev/null
rpc process-capture 200 '{"method":"process.spawn","params":{"executable":"ps","arguments":["-A"],"timeout_seconds":3}}'
jq -e '.result | .timed_out == false and .exit_code == 0 and (.stdout | length > 0)' "$out/process-capture.json" >/dev/null
cols="comm,comm,comm,comm,comm,comm,comm,comm,comm,comm,comm,comm,comm,comm,comm,comm"
rpc process-capture-cap 200 "$(jq -nc --arg c "$cols" '{method:"process.spawn",params:{executable:"ps",arguments:["-A","-o",$c,"-o",$c,"-o",$c,"-o",$c,"-o",$c,"-o",$c],timeout_seconds:2}}')"
jq -e '.result | (.stdout | utf8bytelength) == 65536' "$out/process-capture-cap.json" >/dev/null
# Cross the VSOCK send-buffer boundary in both directions with a new fixture.
dd if=/dev/urandom of="$out/large-transfer.bin" bs=65536 count=4 2>/dev/null
guest_path="/var/mobile/Media/vphone-acceptance-$(uuidgen).bin"
print -r -- "$guest_path" > "$out/guest-transfer-path.txt"
url="$base/v1/files/content?path=$guest_path"
request large-upload 200 -X PUT -H 'Content-Type: application/octet-stream' \
    --data-binary "@$out/large-transfer.bin" "$url"
request large-download 200 "$url"
cmp "$out/large-transfer.bin" "$out/large-download.json"
rpc large-remove 200 "$(jq -nc --arg path "$guest_path" '{method:"files.remove",params:{path:$path}}')"
request health-after 200 "$base/v1/health"
jq -e --arg expected "$expected" --slurpfile before "$out/health-before.json" \
    '.binary_hash == $expected and .instance == $before[0].instance' "$out/health-after.json" >/dev/null
rpc kickstart-vphoned 502 '{"method":"services.kickstart","params":{"label":"com.vphone.vphoned","kill":true,"force":true}}'
jq -e '.error.code == "guest_closed"' "$out/kickstart-vphoned.json" >/dev/null
sleep 3
request health-reconnected 200 "$base/v1/health"
jq -e --arg expected "$expected" --slurpfile before "$out/health-before.json" \
    '.binary_hash == $expected and .instance != $before[0].instance and .status == "ok"' "$out/health-reconnected.json" >/dev/null

print -r -- "RPC stability evidence: $out"

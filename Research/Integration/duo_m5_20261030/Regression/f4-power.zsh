#!/bin/zsh
# F4: Safari on the inner display, close, press power 0.1 s later; repeated.
# Records the window output and samples `device.screen` after each power
# press and wake. The recorder repeats the last frame while the display is
# off, so each trial's frame classes are listed in order: inner Safari,
# cover Safari, black, lock screen, transition. A cover Safari frame can only
# come after the power press, since a close hand-over takes over 200 ms.
#   f4-power.zsh <baseline|candidate> <new-output-directory> [trials]
set -euo pipefail
source "${0:a:h}/rpc-request.zsh"
source "${0:a:h}/host-request.zsh"

repo_root="$(cd "${0:a:h}/../../../.." && pwd)"
variant="${1:?usage: f4-power.zsh <baseline|candidate> <new-output-directory> [trials]}"
output_root="${2:?new evidence directory required}"
trials="${3:-5}"
[[ "$variant" == baseline || "$variant" == candidate ]] || exit 2
[[ "$trials" == <-> ]] && (( trials > 0 && trials <= 20 )) || exit 2
machine="duo-$variant-20261030"
socket_path="$repo_root/.build/acceptance/machines/$machine/vphone.sock"
[[ -S "$socket_path" && "$output_root" == "$repo_root/.build/"* && ! -e "$output_root" ]] || exit 2
mkdir -p "$output_root"
cp "${0:a}" "$output_root/driver.zsh"
shasum -a 256 "${0:a}" > "$output_root/driver-sha256.txt"
git -C "$repo_root" rev-parse HEAD > "$output_root/source-sha.txt"
cp "${0:a:h}/../Historical/fold214/f3/touch-server.mjs" "$output_root/touch-server.mjs"
node "$output_root/touch-server.mjs" &
server_pid=$!
trap 'kill $server_pid 2>/dev/null' EXIT

rpc() { vphone_host_request "$socket_path" "$(vphone_rpc_request "$@")"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }
# The recorder helpers and alert handling are shared with the F5 runner.
vm_pid=$(pgrep -f "vphone-vm.*$machine" | head -1)
eval "$(sed -n '/^recorder() {/,/^}/p;/^dismiss_alert() {/,/^}/p' "${0:a:h}/f5-record.zsh")"
actions="$output_root/actions.tsv"
mark() { printf "%.3f\t%s\n" $(( $(now) - t0 )) "$1" >> "$actions"; }
screen_state() { rpc device.screen | jq -c '.result|{locked,screen_off}'; }

idle_title=$(recorder state)
before=$(/bin/ls -t ~/Desktop | grep -E '^vphone-recording' | head -1 || true)
t0=$(now)
recorder press > /dev/null
/bin/sleep 1
[[ "$(recorder state)" != "$idle_title" ]] || { print -u2 "Recorder did not start"; exit 1; }
print -r -- "$t0" > "$output_root/t0.txt"
: > "$actions"
states="$output_root/states.tsv"
print -r -- $'trial\tafter_power\tafter_wake' > "$states"
for trial in {1..$trials}; do
    rpc screen.unlock '{"timeout":30}' > /dev/null
    rpc display.posture '{"hinge":"open"}' > /dev/null
    /bin/sleep 2
    rpc apps.open_url '{"url":"http://192.168.64.1:18766/"}' > /dev/null
    /bin/sleep 4
    mark "close-$trial"
    rpc display.posture '{"hinge":"closed"}' > /dev/null
    /bin/sleep 0.1
    mark "power-$trial"
    rpc input.button '{"name":"power"}' > /dev/null
    /bin/sleep 1
    after_power=$(screen_state)
    /bin/sleep 3
    mark "wake-open-$trial"
    rpc display.posture '{"hinge":"open"}' > /dev/null
    /bin/sleep 2
    after_wake=$(screen_state)
    print -r -- "$trial	$after_power	$after_wake" >> "$states"
    rpc display.posture '{"hinge":"closed"}' > /dev/null
    /bin/sleep 2
done
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
rpc screen.unlock '{"timeout":30}' > /dev/null || true

ffmpeg -v error -i "$output_root/recording.mov" -vf "scale=502:-2,blackframe=amount=0:threshold=24,signalstats,metadata=print:file=$output_root/meta.txt" -f null -
awk '/^frame:/{f=$1; sub("frame:","",f); t=$3; sub("pts_time:","",t)}
     /pblack=/{split($0,a,"="); pb[f]=a[2]; ts[f]=t}
     /YAVG=/{split($0,a,"="); y[f]=a[2]}
     END{for(i in ts) printf "%d\t%.3f\t%d\t%.1f\n", i, ts[i], pb[i], y[i]}' "$output_root/meta.txt" | sort -n > "$output_root/frames.tsv"
# Classes by whole-frame luma, measured on the touch page and lock screens:
# inner Safari ~45, cover Safari ~50, cover lock ~123-133, inner lock ~157.
offset="${F5_OFFSET:-0.7}"
awk -F'\t' -v off="$offset" '
FILENAME==ARGV[1] { if ($2 ~ /^close-/) { n++; at[n]=$1; lab[n]=$2 } ; next }
{ host=$2+off
  for (i=1;i<=n;i++) if (host>=at[i]-0.5 && host<=at[i]+3.5) {
      c = ($3>=99) ? "B" : ($4>=95) ? "L" : ($4>=40 && $4<47.5) ? "Si" : ($4>=47.5 && $4<56) ? "Sc" : "t"
      # Run-length sequence, e.g. "Si:30 t:4 B:2 Sc:1 L:60".
      if (c!=last[i]) { if (last[i]!="") seq[i]=seq[i] last[i] ":" len[i] " "; len[i]=0 }
      len[i]++; last[i]=c; counts[i, c]++ } }
END { for (i=1;i<=n;i++) printf "%s\tcover-safari-frames=%d\tsequence=%s%s:%d\n", lab[i], counts[i,"Sc"], seq[i], last[i], len[i] }' \
    "$actions" "$output_root/frames.tsv" > "$output_root/trials.txt"
cat "$output_root/trials.txt" "$states"
